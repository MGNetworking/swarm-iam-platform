#!/bin/bash
# Vérifie et prépare les prérequis k3s avant déploiement :
# - kubectl disponible et connecté au cluster
# - namespace iam-system présent (créé si absent)
#
# Usage:
#   ./scripts/ensure-infra.sh --env <linux-server|cloud/azure|cloud/aws>
#
# Ce script NE déploie PAS les manifests.

set -euo pipefail

# -------------------------------------------------------------------
# Placement : racine du projet
# -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# -------------------------------------------------------------------
# Options CLI
# -------------------------------------------------------------------
ENV_NAME=""

while [ "${1:-}" != "" ]; do
  case "$1" in
    --env)
      shift
      [ -n "${1:-}" ] || { echo "ERREUR: --env attend une valeur" >&2; exit 2; }
      ENV_NAME="$1"
      shift
      ;;
    -h|--help)
      echo "Usage: ./scripts/ensure-infra.sh --env <linux-server|cloud/azure|cloud/aws>"
      exit 0
      ;;
    *) echo "Option inconnue: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ENV_NAME" ] || { echo "ERREUR: --env est obligatoire" >&2; exit 2; }

# -------------------------------------------------------------------
# Chargement des fichiers .env
# -------------------------------------------------------------------
ENV_DIR="$PROJECT_ROOT/environments/$ENV_NAME"

[ -d "$ENV_DIR" ] || { echo "ERREUR: environnement introuvable: $ENV_DIR" >&2; exit 1; }

shopt -s nullglob
ENV_FILES=("$ENV_DIR/.env" "$ENV_DIR"/*.env)
shopt -u nullglob

set -a
for CONF_FILE in "${ENV_FILES[@]}"; do
  # shellcheck source=/dev/null
  source "$CONF_FILE"
done
set +a

# -------------------------------------------------------------------
# Paramètres
# -------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-iam-system}"
MAX_WAIT="${MAX_WAIT:-300}"
WAIT_INTERVAL="${WAIT_INTERVAL:-10}"

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/tmp}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/ensure-infra.log}"
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
# Helpers
# -------------------------------------------------------------------
check_kubectl() {
  command -v kubectl >/dev/null 2>&1 || die "kubectl introuvable. Installez kubectl ou k3s."
  log "kubectl : $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
}

wait_cluster_ready() {
  local elapsed=0
  log "Vérification connectivité cluster (timeout=${MAX_WAIT}s)..."
  while [ "$elapsed" -lt "$MAX_WAIT" ]; do
    if kubectl cluster-info >/dev/null 2>&1; then
      log "Cluster k3s accessible après ${elapsed}s"
      return 0
    fi
    log "Cluster non accessible (${elapsed}s/${MAX_WAIT}s) -> attente..."
    sleep "$WAIT_INTERVAL"
    elapsed=$((elapsed + WAIT_INTERVAL))
  done
  die "Cluster k3s inaccessible après ${MAX_WAIT}s. Vérifiez que k3s est démarré."
}

ensure_namespace() {
  local ns="$1"
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    log "Namespace OK: $ns"
  else
    log "Création namespace: $ns"
    kubectl create namespace "$ns"
    log "Namespace créé: $ns"
  fi
}

# -------------------------------------------------------------------
# Exécution
# -------------------------------------------------------------------
log "=== ENSURE INFRA (k3s) ==="
log "ENV             : $ENV_NAME"
log "NAMESPACE       : $NAMESPACE"
log "MAX_WAIT        : $MAX_WAIT"

check_kubectl
wait_cluster_ready
ensure_namespace "$NAMESPACE"

log "=== RÉSUMÉ ==="
log "Cluster: $(kubectl config current-context 2>/dev/null || echo 'default')"
log "Namespace $NAMESPACE: $(kubectl get namespace "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $2}')"
log "Nodes:"
kubectl get nodes --no-headers 2>/dev/null | tee -a "$LOG_FILE" || true
log "OK: prérequis infra satisfaits."
