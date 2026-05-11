#!/bin/bash
# Restauration complète depuis un backup daily (produit par backup-daily-cluster.sh)
# Fichier attendu : CLUSTER-YYYY-MM-DD.sql.gz
#
# ATTENTION (destructif) :
# - Arrête Keycloak (scale=0)
# - Restaure toutes les bases contenues dans le dump via psql sur la DB admin
# - Relance Keycloak (scale=1)
#
# Usage:
#   ./postgres_home/scripts/restore-daily-cluster.sh --env <env> <CLUSTER-YYYY-MM-DD.sql.gz>
#
# Exemple:
#   ./postgres_home/scripts/restore-daily-cluster.sh --env linux-server CLUSTER-2025-12-28.sql.gz

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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
      cat <<'EOF'
Usage:
  ./postgres_home/scripts/restore-daily-cluster.sh --env <env> <CLUSTER-YYYY-MM-DD.sql.gz>

Environnements : linux-server | cloud/azure | cloud/aws

Exemple:
  ./postgres_home/scripts/restore-daily-cluster.sh --env linux-server CLUSTER-2025-12-28.sql.gz

ATTENTION (destructif) :
- Arrête Keycloak (scale=0), restaure toutes les bases, relance Keycloak (scale=1)
EOF
      exit 0
      ;;
    --) shift; break ;;
    -*) echo "Option inconnue: $1" >&2; exit 2 ;;
    *)  break ;;
  esac
done

[ -n "$ENV_NAME" ] || { echo "ERREUR: --env est obligatoire" >&2; exit 2; }
BACKUP_FILE="${1:-}"
[ -n "$BACKUP_FILE" ] || { echo "ERREUR: nom du fichier backup obligatoire" >&2; exit 2; }

# -------------------------------------------------------------------
# Chargement .env
# -------------------------------------------------------------------
ENV_DIR="$PROJECT_ROOT/environments/$ENV_NAME"
[ -d "$ENV_DIR" ] || { echo "ERREUR: environnement introuvable: $ENV_DIR" >&2; exit 1; }

shopt -s nullglob
ENV_FILES=("$ENV_DIR/.env" "$ENV_DIR"/*.env)
shopt -u nullglob

[ "${#ENV_FILES[@]}" -gt 0 ] || { echo "ERREUR: aucun fichier .env dans $ENV_DIR" >&2; exit 1; }

set -a
for CONF_FILE in "${ENV_FILES[@]}"; do
  # shellcheck source=/dev/null
  source "$CONF_FILE"
done
set +a

: "${USER_BD:?USER_BD manquant dans .env}"
: "${LOG_DIR:?LOG_DIR manquant dans config.env}"

NAMESPACE="${NAMESPACE:-iam-system}"
ADMIN_DB="${ADMIN_DB:-postgres}"
MAX_WAIT="${MAX_WAIT:-300}"

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0" .sh)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
mkdir -p "$LOG_DIR"

log() { local level="$1"; shift; echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"; }
die() { log ERROR "$*"; exit 1; }

exec > >(tee -a "$LOG_FILE") 2>&1
# shellcheck disable=SC2154
trap 'rc=$?; log ERROR "Échec (rc=$rc) à la ligne $LINENO"; exit $rc' ERR

# -------------------------------------------------------------------
# Vérification du fichier backup
# -------------------------------------------------------------------
BACKUP_PATH="/var/backups/postgresql/$BACKUP_FILE"
[ -f "$BACKUP_PATH" ] || die "Backup introuvable: $BACKUP_PATH"

# -------------------------------------------------------------------
# Trouver le pod PostgreSQL
# -------------------------------------------------------------------
PG_POD="$(kubectl get pod -n "$NAMESPACE" \
  -l app.kubernetes.io/name=postgresql \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" \
  || die "Pod PostgreSQL introuvable dans le namespace $NAMESPACE"
[ -n "$PG_POD" ] || die "Pod PostgreSQL introuvable dans le namespace $NAMESPACE"

# -------------------------------------------------------------------
# Helpers stop / start Keycloak
# -------------------------------------------------------------------
stop_keycloak() {
  log INFO "Arrêt Keycloak (scale=0)..."
  kubectl scale deployment keycloak --replicas=0 -n "$NAMESPACE" 2>&1 | tee -a "$LOG_FILE" || \
    { log WARN "Keycloak absent ou déjà arrêté."; return 0; }
  kubectl wait pod \
    --for=delete \
    -l app.kubernetes.io/name=keycloak \
    -n "$NAMESPACE" \
    --timeout=60s 2>/dev/null || \
    log WARN "Timeout attente suppression pods Keycloak — on continue."
  log INFO "Keycloak arrêté."
}

start_keycloak() {
  log INFO "Démarrage Keycloak (scale=1)..."
  kubectl scale deployment keycloak --replicas=1 -n "$NAMESPACE" 2>&1 | tee -a "$LOG_FILE"
  kubectl rollout status deployment/keycloak \
    -n "$NAMESPACE" --timeout="${MAX_WAIT}s" 2>&1 | tee -a "$LOG_FILE" || \
    log WARN "Keycloak non prêt après timeout — vérifiez: kubectl get pods -n $NAMESPACE"
}

# -------------------------------------------------------------------
# Exécution
# -------------------------------------------------------------------
log INFO "=== START RESTORE DAILY CLUSTER ==="
log INFO "ENV       : $ENV_NAME"
log INFO "Namespace : $NAMESPACE"
log INFO "Pod PG    : $PG_POD"
log INFO "Backup    : $BACKUP_PATH"
log INFO "User      : $USER_BD"
log INFO "Admin DB  : $ADMIN_DB"

echo ""
echo "ATTENTION : restauration destructive — remplace toutes les bases du cluster."
read -r -p "Confirmer le RESTORE COMPLET depuis '$BACKUP_FILE' ? [y/N]: " confirm
case "${confirm,,}" in
  y|yes) log INFO "Confirmation utilisateur: OK" ;;
  *) die "Opération annulée par l'utilisateur." ;;
esac

# 1) Arrêt Keycloak
stop_keycloak

# 2) Vérification rapide du contenu du dump
log INFO "Vérification du dump (présence de directives \\connect)..."
if ! gzip -dc "$BACKUP_PATH" | head -n 100 | grep -q "\\\\connect"; then
  log WARN "Aucune directive \\connect trouvée — le dump est peut-être vide ou corrompu."
fi

# 3) Restore via kubectl exec (pipe gzip → psql dans le pod)
log INFO "RESTORE en cours (gzip → psql -d $ADMIN_DB)..."
gzip -dc "$BACKUP_PATH" | \
  kubectl exec -i -n "$NAMESPACE" "$PG_POD" -- \
    sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d '"\"$ADMIN_DB\""' -v ON_ERROR_STOP=1'

log INFO "OK: restore cluster terminé."

# 4) Relance Keycloak
start_keycloak

log INFO "=== END RESTORE DAILY CLUSTER ==="
