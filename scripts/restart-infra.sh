#!/bin/bash
# Redémarrage contrôlé des déploiements k3s
# Effectue un kubectl rollout restart sur chaque workload du namespace iam-system
# puis attend la stabilisation.
#
# Usage:
#   ./scripts/restart-infra.sh --env <linux-server|cloud/azure|cloud/aws>

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
      echo "Usage: ./scripts/restart-infra.sh --env <linux-server|cloud/azure|cloud/aws>"
      exit 0
      ;;
    *) echo "Option inconnue: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ENV_NAME" ] || { echo "ERREUR: --env est obligatoire" >&2; exit 2; }

# -------------------------------------------------------------------
# Chargement .env
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
# Paramètres / Logging
# -------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-iam-system}"
MAX_WAIT="${MAX_WAIT:-300}"
LOG_DIR="${LOG_DIR:-/tmp}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/restart-infra.log}"
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
restart_and_wait() {
  local kind="$1"
  local name="$2"
  local timeout="${3:-$MAX_WAIT}"

  if ! kubectl get "$kind/$name" -n "$NAMESPACE" >/dev/null 2>&1; then
    log "SKIP: $kind/$name absent du namespace $NAMESPACE"
    return 0
  fi

  log "Restart: $kind/$name"
  kubectl rollout restart "$kind/$name" -n "$NAMESPACE" 2>&1 | tee -a "$LOG_FILE"

  log "Attente stabilisation: $kind/$name (timeout=${timeout}s)"
  kubectl rollout status "$kind/$name" -n "$NAMESPACE" \
    --timeout "${timeout}s" 2>&1 | tee -a "$LOG_FILE" || {
    log "ATTENTION: $kind/$name non stable après ${timeout}s"
    return 1
  }
}

# -------------------------------------------------------------------
# Exécution
# -------------------------------------------------------------------
log "=== RESTART INFRA (k3s) ==="
log "ENV             : $ENV_NAME"
log "NAMESPACE       : $NAMESPACE"

kubectl get pods -n "$NAMESPACE" 2>&1 | tee -a "$LOG_FILE" || true

log "=== REDÉMARRAGE DES WORKLOADS ==="
restart_and_wait "deployment"  "traefik"    180 || true
restart_and_wait "statefulset" "postgresql" 240 || true
restart_and_wait "deployment"  "redis"      180 || true
restart_and_wait "deployment"  "keycloak"   300 || true

log "=== RÉSUMÉ FINAL ==="
kubectl get pods -n "$NAMESPACE" 2>&1 | tee -a "$LOG_FILE" || true
log "Restart terminé."
