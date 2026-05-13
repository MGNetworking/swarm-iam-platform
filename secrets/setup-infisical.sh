#!/bin/bash
# Crée le secret Kubernetes contenant les credentials Infisical.
# C'est le seul secret encore créé manuellement — ESO utilise ces credentials
# pour s'authentifier auprès d'Infisical et synchroniser tous les autres secrets.
#
# Prérequis :
#   - ESO installé (scripts/setup-eso.sh)
#   - INFISICAL_CLIENT_ID et INFISICAL_CLIENT_SECRET dans environments/<env>/.env
#
# Idempotent — safe à relancer si les credentials changent.
#
# Usage:
#   ./secrets/setup-infisical.sh --env linux-server

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/log/secrets}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/setup-infisical_$(date '+%Y-%m-%d_%H-%M-%S').log}"
mkdir -p "$LOG_DIR" || { echo "ERREUR: impossible de créer LOG_DIR=$LOG_DIR"; exit 1; }
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) - $*" | tee -a "$LOG_FILE"; }

# -------------------------------------------------------------------
# Options CLI
# -------------------------------------------------------------------
ENV_NAME=""

while [ "${1:-}" != "" ]; do
  case "$1" in
    --env)
      shift
      [ -n "${1:-}" ] || { log "ERREUR: --env attend une valeur"; exit 2; }
      ENV_NAME="$1"
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: ./secrets/setup-infisical.sh --env <environnement>

--env   Environnement cible (linux-server, local-dev, cloud/azure, cloud/aws)

Ce script lit INFISICAL_CLIENT_ID et INFISICAL_CLIENT_SECRET depuis
environments/<env>/.env et crée le secret K8s "infisical-credentials"
dans le namespace "external-secrets" (namespace d'ESO).
EOF
      exit 0
      ;;
    *) log "Option inconnue: $1"; exit 2 ;;
  esac
done

[ -n "$ENV_NAME" ] || { log "ERREUR: --env est obligatoire. Ex: --env linux-server"; exit 2; }

# -------------------------------------------------------------------
# Chargement .env
# -------------------------------------------------------------------
ENV_DIR="$PROJECT_ROOT/environments/$ENV_NAME"
[ -d "$ENV_DIR" ] || { log "ERREUR: environnement introuvable: $ENV_DIR"; exit 1; }

shopt -s nullglob
ENV_FILES=("$ENV_DIR/.env" "$ENV_DIR"/*.env)
shopt -u nullglob

[ "${#ENV_FILES[@]}" -gt 0 ] || { log "ERREUR: aucun .env trouvé dans $ENV_DIR"; exit 1; }

set -a
for CONF_FILE in "${ENV_FILES[@]}"; do
  # shellcheck source=/dev/null
  source "$CONF_FILE"
done
set +a

: "${INFISICAL_CLIENT_ID:?INFISICAL_CLIENT_ID manquant dans environments/$ENV_NAME/.env}"
: "${INFISICAL_CLIENT_SECRET:?INFISICAL_CLIENT_SECRET manquant dans environments/$ENV_NAME/.env}"

# -------------------------------------------------------------------
# Prérequis
# -------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1  || { log "ERREUR: kubectl introuvable"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { log "ERREUR: cluster inaccessible"; exit 1; }

kubectl get namespace external-secrets >/dev/null 2>&1 || {
  log "ERREUR: namespace 'external-secrets' introuvable."
  log "Lancez d'abord : ./scripts/setup-eso.sh"
  exit 1
}

# -------------------------------------------------------------------
# Création du secret infisical-credentials
# Les valeurs ne sont jamais loggées.
# -------------------------------------------------------------------
log "=== SETUP INFISICAL CREDENTIALS ==="
log "ENV       : $ENV_NAME"
log "Namespace : external-secrets"

log "Création du secret infisical-credentials..."
kubectl create secret generic infisical-credentials \
  --from-literal=clientId="$INFISICAL_CLIENT_ID" \
  --from-literal=clientSecret="$INFISICAL_CLIENT_SECRET" \
  -n external-secrets \
  --dry-run=client -o yaml | kubectl apply -f - 2>&1 | tee -a "$LOG_FILE"

log "OK: secret infisical-credentials créé dans le namespace external-secrets."
log "Étape suivante : ./scripts/deploy-infra.sh --env $ENV_NAME"
log "=== END SETUP INFISICAL ==="
