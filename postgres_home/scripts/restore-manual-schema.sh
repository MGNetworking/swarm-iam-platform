#!/bin/bash
# Restore schema depuis backups/manual/schema/
# Procédure: drop schema cascade + recreate + restore (dans la DB ciblée)
# ATTENTION: destructif pour le schema ciblé.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# =========================
# Chargement des fichiers .env
# =========================

ENV_DIR="$PROJECT_ROOT/environments/homeLab"

shopt -s nullglob
ENV_FILES=(
  "$ENV_DIR/.env"
  "$ENV_DIR"/*.env
)
shopt -u nullglob

if [ "${#ENV_FILES[@]}" -eq 0 ]; then
  echo "Aucun fichier .env trouvé dans $ENV_DIR" >&2
  exit 1
fi

set -a
for CONF_FILE in "${ENV_FILES[@]}"; do
  # shellcheck source=/dev/null
  source "$CONF_FILE"
done
set +a

: "${PG_STACK_NAME:?PG_STACK_NAME manquant dans .env}"
: "${LOG_DIR:?LOG_DIR manquant dans config.env}"

# Vos variables (selon ce que vous m'avez donné)
: "${USER_BD:?USER_BD manquant dans .env}"
# DB_NAME peut exister dans .env (chez vous oui), mais la DB cible sera déduite du fichier.
DB_NAME_ENV="${DB_NAME:-}"

# =========================
# Logging (hôte)
# =========================
SCRIPT_NAME="$(basename "$0" .sh)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"

mkdir -p "$LOG_DIR"

log() {
  local level="$1"; shift
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
}

# stdout + stderr -> console + fichier
exec > >(tee -a "$LOG_FILE") 2>&1

# shellcheck disable=SC2154
trap 'rc=$?; log ERROR "Échec (rc=$rc) à la ligne $LINENO"; exit $rc' ERR

log INFO "=== START RESTORE SCHEMA (MANUAL) ==="
log INFO "Project root : $PROJECT_ROOT"
log INFO "Env dir      : $ENV_DIR"
log INFO "Env files    : ${ENV_FILES[*]}"
log INFO "Log file     : $LOG_FILE"

SERVICE="${PG_STACK_NAME}_postgres-shared"
BACKUP_DIR_HOST="$PROJECT_ROOT/postgres_home/backups/manual/schema"

usage() {
  cat <<'EOF'
Usage (recommandé):
  ./postgres_home/scripts/restore-manual-schema.sh <backup_file.sql.gz>

Le script déduit automatiquement DB et SCHEMA depuis le nom du fichier :
  SCHEMA-YYYY-MM-DD_HH-MM-SS-<db_name>__<schema_name>.sql.gz

Exemple:
  ./postgres_home/scripts/restore-manual-schema.sh SCHEMA-2025-12-21_14-05-00-kc_db__public.sql.gz

Mode legacy (compatibilité) :
  ./postgres_home/scripts/restore-manual-schema.sh <db_name> <schema_name> <backup_file.sql.gz>
EOF
}

# =========================
# Args + déduction db/schema depuis filename
# =========================
TARGET_DB=""
TARGET_SCHEMA=""
BACKUP_FILE=""

if [ "$#" -eq 1 ]; then
  BACKUP_FILE="$1"

  # SCHEMA-2025-12-21_14-05-00-kc_db__public.sql.gz
  if [[ "$BACKUP_FILE" =~ ^SCHEMA-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}-(.+)__([^./]+)\.sql\.gz$ ]]; then
    TARGET_DB="${BASH_REMATCH[1]}"
    TARGET_SCHEMA="${BASH_REMATCH[2]}"
  else
    log ERROR "Nom de fichier invalide: $BACKUP_FILE"
    log ERROR "Format attendu: SCHEMA-YYYY-MM-DD_HH-MM-SS-<db_name>__<schema_name>.sql.gz"
    usage
    exit 2
  fi

elif [ "$#" -eq 3 ]; then
  # legacy
  TARGET_DB="$1"
  TARGET_SCHEMA="$2"
  BACKUP_FILE="$3"

else
  usage
  exit 2
fi

BACKUP_PATH_HOST="$BACKUP_DIR_HOST/$BACKUP_FILE"
[ -f "$BACKUP_PATH_HOST" ] || { log ERROR "Backup introuvable: $BACKUP_PATH_HOST"; exit 1; }

# Avertissement si DB_NAME env != db du fichier (chez vous: DB_NAME=kc_db)
if [ -n "$DB_NAME_ENV" ] && [ "$DB_NAME_ENV" != "$TARGET_DB" ]; then
  log WARN "DB_NAME env ($DB_NAME_ENV) différent de la DB déduite du backup ($TARGET_DB). Je restaure la DB du fichier."
fi

CID="$(docker ps --filter "name=${SERVICE}" -q | head -n1)"
[ -n "$CID" ] || { log ERROR "Conteneur Postgres introuvable (service=$SERVICE)"; exit 1; }

log INFO "DB        : $TARGET_DB"
log INFO "Schema    : $TARGET_SCHEMA"
log INFO "Backup    : $BACKUP_PATH_HOST"
log INFO "Container : $CID"
log INFO "User      : $USER_BD"

echo ""
echo "CONFIRMATION requise."
echo "Vous allez DROPPER puis RESTAURER le schema \"$TARGET_SCHEMA\" dans la DB \"$TARGET_DB\"."
read -r -p "Tapez EXACTEMENT 'RESTORE-SCHEMA' pour continuer: " confirm
[ "$confirm" = "RESTORE-SCHEMA" ] || { log INFO "Annulé par l'utilisateur."; exit 1; }

log INFO "DROP / CREATE schema..."

docker exec "$CID" sh -c "
  export PGPASSWORD=\"\$(cat /run/secrets/pg_password)\";

  # Ferme les connexions sur la DB cible (robuste)
  psql -U \"${USER_BD}\" -d template1 -v ON_ERROR_STOP=1 -c \
    \"SELECT pg_terminate_backend(pid)
     FROM pg_stat_activity
     WHERE datname='${TARGET_DB}' AND pid <> pg_backend_pid();\" || true

  # Drop schema (le dump se charge de le recréer si nécessaire)
  psql -U \"${USER_BD}\" -d \"${TARGET_DB}\" -v ON_ERROR_STOP=1 -c \
    \"DROP SCHEMA IF EXISTS \\\"${TARGET_SCHEMA}\\\" CASCADE;\"
"

log INFO "RESTORE schema en cours..."
gzip -dc "$BACKUP_PATH_HOST" | docker exec -i "$CID" sh -c "
  export PGPASSWORD=\"\$(cat /run/secrets/pg_password)\";
  psql -U \"${USER_BD}\" -d \"${TARGET_DB}\" -v ON_ERROR_STOP=1
"

log INFO "OK: restore schema terminé."
log INFO "=== END RESTORE SCHEMA (MANUAL) ==="
