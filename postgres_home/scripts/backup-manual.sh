#!/bin/bash
# Backup manuel interactif via kubectl exec
# - Choix: (1) base complète  (2) schéma uniquement
# - Sélection de la base par numéro

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# -------------------------------------------------------------------
# Chargement .env
# -------------------------------------------------------------------
ENV_NAME="${INFRA_ENV:-linux-server}"
ENV_DIR="$PROJECT_ROOT/environments/$ENV_NAME"

shopt -s nullglob
ENV_FILES=("$ENV_DIR/.env" "$ENV_DIR"/*.env)
shopt -u nullglob

[ "${#ENV_FILES[@]}" -gt 0 ] || { echo "ERREUR: aucun .env trouvé dans $ENV_DIR" >&2; exit 1; }

set -a
for CONF_FILE in "${ENV_FILES[@]}"; do
  # shellcheck source=/dev/null
  source "$CONF_FILE"
done
set +a

: "${USER_BD:?USER_BD manquant dans .env}"
: "${DB_NAME:?DB_NAME manquant dans .env}"
: "${LOG_DIR:?LOG_DIR manquant dans config.env}"

NAMESPACE="${NAMESPACE:-iam-system}"

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0" .sh)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
mkdir -p "$LOG_DIR"

log() { local level="$1"; shift; echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" | tee -a "$LOG_FILE"; }

# -------------------------------------------------------------------
# Pod PostgreSQL
# -------------------------------------------------------------------
PG_POD="$(kubectl get pod -n "$NAMESPACE" \
  -l app.kubernetes.io/name=postgresql \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" \
  || { log ERROR "Pod PostgreSQL introuvable dans $NAMESPACE"; exit 1; }
[ -n "$PG_POD" ] || { log ERROR "Pod PostgreSQL introuvable dans $NAMESPACE"; exit 1; }

# -------------------------------------------------------------------
# Choix du type de backup
# -------------------------------------------------------------------
echo ""
echo "=== BACKUP MANUEL POSTGRESQL (k3s) ==="
echo "Namespace : $NAMESPACE"
echo "Pod       : $PG_POD"
echo ""
echo "Type de backup :"
echo "  1) Base complète (données + schéma)"
echo "  2) Schéma uniquement"
echo ""
read -r -p "Choix [1/2]: " BACKUP_TYPE

case "$BACKUP_TYPE" in
  1) MODE="full" ;;
  2) MODE="schema" ;;
  *) echo "Choix invalide"; exit 1 ;;
esac

# -------------------------------------------------------------------
# Sélection de la base
# -------------------------------------------------------------------
echo ""
echo "Bases disponibles :"
mapfile -t DBS < <(kubectl exec -n "$NAMESPACE" "$PG_POD" -- \
  sh -c 'psql -U "$POSTGRES_USER" -d postgres -Atc "SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY datname;"' \
  2>/dev/null)

for i in "${!DBS[@]}"; do
  echo "  $((i+1))) ${DBS[$i]}"
done
echo ""
read -r -p "Numéro de la base [défaut: $DB_NAME]: " DB_CHOICE

if [ -z "$DB_CHOICE" ]; then
  SELECTED_DB="$DB_NAME"
else
  idx=$((DB_CHOICE - 1))
  SELECTED_DB="${DBS[$idx]:-}"
  [ -n "$SELECTED_DB" ] || { echo "Choix invalide"; exit 1; }
fi

# -------------------------------------------------------------------
# Backup
# -------------------------------------------------------------------
DATE="$(date +%Y-%m-%d_%H%M%S)"

if [ "$MODE" = "full" ]; then
  OUT_DIR="$PROJECT_ROOT/postgres_home/backups/manual/BD"
  OUT_FILE="${OUT_DIR}/${SELECTED_DB}-${DATE}.sql.gz"
  mkdir -p "$OUT_DIR"

  log INFO "Backup complet: $SELECTED_DB -> $OUT_FILE"
  kubectl exec -n "$NAMESPACE" "$PG_POD" -- \
    sh -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" pg_dump -U \"\$POSTGRES_USER\" -d \"$SELECTED_DB\" --format=plain --no-owner --no-privileges" \
    | gzip -9 > "$OUT_FILE"

else
  OUT_DIR="$PROJECT_ROOT/postgres_home/backups/manual/schema"
  OUT_FILE="${OUT_DIR}/${SELECTED_DB}-schema-${DATE}.sql.gz"
  mkdir -p "$OUT_DIR"

  log INFO "Backup schéma: $SELECTED_DB -> $OUT_FILE"
  kubectl exec -n "$NAMESPACE" "$PG_POD" -- \
    sh -c "PGPASSWORD=\"\$POSTGRES_PASSWORD\" pg_dump -U \"\$POSTGRES_USER\" -d \"$SELECTED_DB\" --schema-only --no-owner --no-privileges" \
    | gzip -9 > "$OUT_FILE"
fi

[ -s "$OUT_FILE" ] || { log ERROR "Backup vide ou échec: $OUT_FILE"; rm -f "$OUT_FILE"; exit 1; }
log INFO "OK: $OUT_FILE ($(du -sh "$OUT_FILE" | cut -f1))"
