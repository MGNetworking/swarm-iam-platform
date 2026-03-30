#!/bin/bash
# Restore DB complète depuis backups/manual/BD/
# Procédure: drop DB + create DB + restore
# ATTENTION: destructif pour la base ciblée.
#
# Usage:
#   ./postgres_home/scripts/restore-manual-db.sh <backup_file.sql.gz>
#
# Format attendu:
#   DB-YYYY-MM-DD_HH-MM-SS-<db_name>.sql.gz

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
  # shellcheck disable=SC1090
  source "$CONF_FILE"
done
set +a

: "${PG_STACK_NAME:?PG_STACK_NAME manquant dans .env}"
: "${LOG_DIR:?LOG_DIR manquant dans config.env}"
: "${DB_NAME:?DB_NAME manquant dans .env}"
: "${USER_BD:?USER_BD manquant dans .env}"

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

# log en cas d'erreur
# shellcheck disable=SC2154
trap 'rc=$?; log ERROR "Échec (rc=$rc) à la ligne $LINENO"; exit $rc' ERR

log INFO "=== START RESTORE DB (MANUAL) ==="
log INFO "Project root : $PROJECT_ROOT"
log INFO "Env dir      : $ENV_DIR"
log INFO "Env files    : ${ENV_FILES[*]}"
log INFO "Log file     : $LOG_FILE"

SERVICE="${PG_STACK_NAME}_postgres-shared"
BACKUP_DIR_HOST="$PROJECT_ROOT/postgres_home/backups/manual/BD"

usage() {
  cat <<EOF
Usage: ./postgres_home/scripts/restore-manual-db.sh <backup_file.sql.gz>

Format attendu:
  DB-YYYY-MM-DD_HH-MM-SS-<db_name>.sql.gz

Exemple:
  ./postgres_home/scripts/restore-manual-db.sh DB-2025-12-21_14-05-00-kc_db.sql.gz
EOF
}

# =========================
# Args + déduction DB depuis le nom de fichier
# =========================
BACKUP_FILE="${1:-}"
[ -n "$BACKUP_FILE" ] || { usage; exit 2; }

if [[ "$BACKUP_FILE" != *.sql.gz ]]; then
  log ERROR "Le fichier doit se terminer par .sql.gz : $BACKUP_FILE"
  usage
  exit 2
fi

base="${BACKUP_FILE%.sql.gz}"
DB_NAME_FROM_FILE="${base##*-}"

if [[ -z "$DB_NAME_FROM_FILE" ]]; then
  log ERROR "Impossible de déduire le nom de DB depuis: $BACKUP_FILE"
  usage
  exit 2
fi

# garde-fou nom DB (évite surprises / caractères inattendus)
if [[ ! "$DB_NAME_FROM_FILE" =~ ^[a-zA-Z0-9_]+$ ]]; then
  log ERROR "Nom de DB déduit invalide: '$DB_NAME_FROM_FILE' (autorisé: a-zA-Z0-9_)"
  log ERROR "Vérifiez le format du fichier: DB-YYYY-MM-DD_HH-MM-SS-<db_name>.sql.gz"
  exit 2
fi

# garde-fou cohérence avec l'env
if [[ "$DB_NAME_FROM_FILE" != "$DB_NAME" ]]; then
  log ERROR "Incohérence: DB déduite du fichier = '$DB_NAME_FROM_FILE' mais DB_NAME (env) = '$DB_NAME'"
  log ERROR "Refus pour éviter une restauration dans une mauvaise base."
  exit 2
fi

BACKUP_PATH_HOST="$BACKUP_DIR_HOST/$BACKUP_FILE"
[ -f "$BACKUP_PATH_HOST" ] || { log ERROR "Backup introuvable: $BACKUP_PATH_HOST"; exit 1; }

CID="$(docker ps --filter "name=${SERVICE}" -q | head -n1)"
[ -n "$CID" ] || { log ERROR "Conteneur Postgres introuvable (service=$SERVICE)"; exit 1; }

log INFO "DB (env)      : $DB_NAME"
log INFO "DB (fichier)  : $DB_NAME_FROM_FILE"
log INFO "User (admin)  : $USER_BD"
log INFO "Backup        : $BACKUP_PATH_HOST"
log INFO "Container     : $CID"

echo ""
echo "CONFIRMATION requise."
echo "Vous allez DROPPER puis RECRÉER la base: $DB_NAME"
read -r -p "Confirmer la restauration ? [y/N] : " confirm

case "$confirm" in
  y|Y)
    log INFO "Confirmation utilisateur reçue. Démarrage de la restauration."
    ;;
  *)
    log INFO "Restauration annulée par l'utilisateur."
    exit 1
    ;;
esac

log INFO "DROP / CREATE DB..."

docker exec "$CID" sh -c "
  export PGPASSWORD=\"\$(cat /run/secrets/pg_password)\";

  # Ferme les connexions sur la DB cible
  psql -U \"${USER_BD}\" -d template1 -v ON_ERROR_STOP=1 -c \
    \"SELECT pg_terminate_backend(pid)
     FROM pg_stat_activity
     WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();\" || true

  # Drop / Create via template1 (robuste)
  psql -U \"${USER_BD}\" -d template1 -v ON_ERROR_STOP=1 -c \
    \"DROP DATABASE IF EXISTS \\\"${DB_NAME}\\\";\"

  psql -U \"${USER_BD}\" -d template1 -v ON_ERROR_STOP=1 -c \
    \"CREATE DATABASE \\\"${DB_NAME}\\\";\"
"

log INFO "RESTORE DB en cours..."
gzip -dc "$BACKUP_PATH_HOST" | docker exec -i "$CID" sh -c "
  export PGPASSWORD=\"\$(cat /run/secrets/pg_password)\";
  psql -U \"${USER_BD}\" -d \"${DB_NAME}\" -v ON_ERROR_STOP=1
"

log INFO "OK: restore DB terminé."
log INFO "=== END RESTORE DB (MANUAL) ==="
