#!/bin/bash
# Déploiement de la plateforme IAM sur k3s via Kustomize
#
# Options:
#   --env <env>   : environnement cible (obligatoire)
#                   valeurs: linux-server | cloud/azure | cloud/aws
#   --no-wait     : ne pas attendre la stabilisation des pods
#
# Exemples:
#   ./scripts/deploy-infra.sh --env linux-server
#   ./scripts/deploy-infra.sh --env cloud/azure --no-wait

set -euo pipefail

# -------------------------------------------------------------------
# Placement : racine du projet, quel que soit le cwd
# -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# -------------------------------------------------------------------
# Options CLI
# -------------------------------------------------------------------
ENV_NAME=""
NO_WAIT="false"

while [ "${1:-}" != "" ]; do
  case "$1" in
    --env)
      shift
      [ -n "${1:-}" ] || { echo "ERREUR: --env attend une valeur (ex: linux-server)" >&2; exit 2; }
      ENV_NAME="$1"
      shift
      ;;
    --no-wait) NO_WAIT="true"; shift ;;
    -h|--help)
      cat <<EOF
Usage: ./scripts/deploy-infra.sh --env <environnement> [--no-wait]

Environnements disponibles:
  linux-server    VPS bare metal avec k3s
  cloud/azure     Azure Kubernetes Service (AKS)
  cloud/aws       Elastic Kubernetes Service (EKS)

Options:
  --no-wait   Ne pas attendre la stabilisation des pods
  -h, --help  Afficher cette aide
EOF
      exit 0
      ;;
    *) echo "Option inconnue: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ENV_NAME" ] || { echo "ERREUR: --env est obligatoire. Ex: --env linux-server" >&2; exit 2; }

# -------------------------------------------------------------------
# Chargement des fichiers .env
# -------------------------------------------------------------------
ENV_DIR="$PROJECT_ROOT/environments/$ENV_NAME"

[ -d "$ENV_DIR" ] || { echo "ERREUR: environnement introuvable: $ENV_DIR" >&2; exit 1; }

shopt -s nullglob
ENV_FILES=("$ENV_DIR/.env" "$ENV_DIR"/*.env)
shopt -u nullglob

[ "${#ENV_FILES[@]}" -gt 0 ] || { echo "ERREUR: aucun fichier .env trouvé dans $ENV_DIR" >&2; exit 1; }

set -a
for CONF_FILE in "${ENV_FILES[@]}"; do
  # shellcheck source=/dev/null
  source "$CONF_FILE"
done
set +a

# -------------------------------------------------------------------
# Paramètres
# -------------------------------------------------------------------
ENSURE_INFRA_SCRIPT="$PROJECT_ROOT/scripts/ensure-infra.sh"
ENSURE_BACKUP_SCRIPT="$PROJECT_ROOT/scripts/ensure-backup-dirs.sh"
K8S_OVERLAY="${K8S_OVERLAY:-k8s/overlays/$ENV_NAME}"
NAMESPACE="${NAMESPACE:-iam-system}"
MAX_WAIT="${MAX_WAIT:-300}"
WAIT_INTERVAL="${WAIT_INTERVAL:-10}"

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/tmp}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/deploy-infra.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}"

mkdir -p "$LOG_DIR" || { echo "ERREUR: impossible de créer LOG_DIR=$LOG_DIR"; exit 1; }

rotate_log_if_needed() {
  if [ -f "$LOG_FILE" ]; then
    local size
    size="$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
    if [ "$size" -ge "$LOG_MAX_BYTES" ] 2>/dev/null; then
      mv -f "$LOG_FILE" "${LOG_FILE}.1" >/dev/null 2>&1 || true
    fi
  fi
}

rotate_log_if_needed

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) - $*" | tee -a "$LOG_FILE"; }
die() { log "ERREUR: $*"; exit 1; }

on_error() {
  local exit_code=$?
  log "ERREUR: commande échouée (exit=$exit_code) à la ligne $1: $2"
  exit "$exit_code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# -------------------------------------------------------------------
# Variables requises
# -------------------------------------------------------------------
: "${KEYCLOAK_HOSTNAME:?KEYCLOAK_HOSTNAME manquant dans $ENV_DIR/.env}"
: "${NAMESPACE:?NAMESPACE manquant}"
: "${K8S_OVERLAY:?K8S_OVERLAY manquant dans $ENV_DIR/config.env}"

[ -d "$PROJECT_ROOT/$K8S_OVERLAY" ] || die "Overlay Kustomize introuvable: $PROJECT_ROOT/$K8S_OVERLAY"

# -------------------------------------------------------------------
# Attente readiness d'un déploiement ou statefulset
# -------------------------------------------------------------------
wait_rollout() {
  local kind="$1"
  local name="$2"
  local timeout="${3:-$MAX_WAIT}"

  if [ "$NO_WAIT" = "true" ]; then
    log "NO_WAIT=true -> skip attente: $kind/$name"
    return 0
  fi

  log "Attente readiness: $kind/$name (timeout=${timeout}s)"
  kubectl rollout status "$kind/$name" \
    --namespace "$NAMESPACE" \
    --timeout "${timeout}s" 2>&1 | tee -a "$LOG_FILE" || {
    log "ATTENTION: $kind/$name non prêt après ${timeout}s"
    return 1
  }
}

probe_keycloak() {
  command -v curl >/dev/null 2>&1 || return 2
  local kc_ip
  kc_ip="$(kubectl get service traefik -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  [ -n "$kc_ip" ] || return 2
  curl -fsS -H "Host: ${KEYCLOAK_HOSTNAME}" \
    "http://${kc_ip}/health" >/dev/null 2>&1
}

# -------------------------------------------------------------------
# Exécution
# -------------------------------------------------------------------
log "=== DÉPLOIEMENT IAM PLATFORM (k3s / Kustomize) ==="
log "ENV             : $ENV_NAME"
log "NAMESPACE       : $NAMESPACE"
log "K8S_OVERLAY     : $K8S_OVERLAY"
log "KEYCLOAK_HOST   : $KEYCLOAK_HOSTNAME"
log "NO_WAIT         : $NO_WAIT"
log "MAX_WAIT        : $MAX_WAIT"

# 1) Prérequis infra (k3s + kubectl + namespace)
log "=== ENSURE INFRA ==="
chmod +x "$ENSURE_INFRA_SCRIPT" || true
"$ENSURE_INFRA_SCRIPT" --env "$ENV_NAME"

# 2) Répertoires backup
log "=== ENSURE BACKUP DIRS ==="
[ -f "$ENSURE_BACKUP_SCRIPT" ] || die "Script introuvable: $ENSURE_BACKUP_SCRIPT"
chmod +x "$ENSURE_BACKUP_SCRIPT" || true
"$ENSURE_BACKUP_SCRIPT" --env "$ENV_NAME"

# 3) Application des manifests Kustomize
log "=== KUBECTL APPLY -K $K8S_OVERLAY ==="
kubectl apply -k "$PROJECT_ROOT/$K8S_OVERLAY" 2>&1 | tee -a "$LOG_FILE"

# 4) Attente stabilisation (ordre de dépendance)
log "=== ATTENTE STABILISATION DES PODS ==="
wait_rollout "deployment"   "traefik"    180 || true
wait_rollout "statefulset"  "postgresql" 240 || true
wait_rollout "deployment"   "redis"      180 || true
wait_rollout "deployment"   "keycloak"   300 || true

# 5) Probe Keycloak
log "=== PROBE KEYCLOAK ==="
if probe_keycloak; then
  log "OK: Keycloak accessible via Traefik -> Host:${KEYCLOAK_HOSTNAME}"
else
  rc=$?
  if [ "$rc" -eq 2 ]; then
    log "INFO: probe ignorée (curl absent ou IP Traefik indisponible)"
  else
    log "ATTENTION: Keycloak non joignable. Vérifiez les pods et l'Ingress."
  fi
fi

# 6) Résumé
log "=== RÉSUMÉ ==="
kubectl get pods -n "$NAMESPACE" 2>&1 | tee -a "$LOG_FILE" || true
log "Déploiement terminé."
