#!/bin/bash
# Backup daily: toutes les DB du cluster en UN SEUL fichier (sans rôles)
# - 1 fichier / jour
# - purge automatique > 30 jours
#
# Restore ensuite via:
#   gzip -dc CLUSTER-YYYY-MM-DD.sql.gz | docker exec -i <CID> sh -c 'export PGPASSWORD="$(cat /run/secrets/pg_password)"; psql -U "$USER_BD" -d postgres -v ON_ERROR_STOP=1'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

ENV_DIR="$PROJECT_ROOT/environments/homeLab"

shopt -s nullglob
ENV_FILES=("$ENV_DIR/.env" "$ENV_DIR"/*.env)
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
: "${USER_BD:?USER_BD manquant dans .env (ex: max_admin)}"

SCRIPT_NAME="$(basename "$0" .sh)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
mkdir -p "$LOG_DIR"

log() { local level="$1"; shift; echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"; }

exec > >(tee -a "$LOG_FILE") 2>&1
# shellcheck disable=SC2154
trap 'rc=$?; log ERROR "Échec (rc=$rc) à la ligne $LINENO"; exit $rc' ERR

SERVICE="${PG_STACK_NAME}_postgres-shared"
CID="$(docker ps --filter "name=${SERVICE}" -q | head -n1)"
[ -n "$CID" ] || { log ERROR "Conteneur Postgres introuvable (service=$SERVICE)"; exit 1; }

OUT_DIR="/var/backups/daily/cluster"
DATE="$(date +%Y-%m-%d)"
OUT_FILE="${OUT_DIR}/CLUSTER-${DATE}.sql.gz"
KEEP_DAYS="${PG_BACKUP_KEEP_DAYS:-30}"
ADMIN_DB="${ADMIN_DB:-postgres}"

log INFO "=== START BACKUP DAILY CLUSTER (ONE FILE, NO ROLES) ==="
log INFO "Project root : $PROJECT_ROOT"
log INFO "Env files    : ${ENV_FILES[*]}"
log INFO "Service      : $SERVICE"
log INFO "Container    : $CID"
log INFO "Admin DB     : $ADMIN_DB"
log INFO "User (dump)  : $USER_BD"
log INFO "Output       : $OUT_FILE"
log INFO "Retention(d) : $KEEP_DAYS"

if docker exec "$CID" sh -c "[ -f '$OUT_FILE' ]"; then
  log INFO "SKIP: backup déjà présent pour aujourd'hui: $OUT_FILE"
else
  log INFO "RUN : génération CLUSTER SQL -> $OUT_FILE"

  docker exec "$CID" sh -c "
    set -e
    test -d '$OUT_DIR' || exit 3
    export PGPASSWORD=\"\$(cat /run/secrets/pg_password)\"

    tmp='${OUT_FILE}.tmp'

    {
      echo \"-- CLUSTER BACKUP (NO ROLES) - ${DATE}\"
      echo \"\\\\set ON_ERROR_STOP on\"
      echo \"\"

      # Vérifier DB admin accessible
      psql -U \"$USER_BD\" -d \"$ADMIN_DB\" -Atc \"SELECT 1;\" >/dev/null

      DBS=\$(psql -U \"$USER_BD\" -d \"$ADMIN_DB\" -Atc \"SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY datname;\")
      [ -n \"\$DBS\" ] || exit 20

      for db in \$DBS; do
        if [ \"\$db\" = \"$ADMIN_DB\" ]; then
          continue
        fi

        echo \"\"
        echo \"-- ==========================================================\"
        echo \"-- DATABASE: \$db\"
        echo \"-- ==========================================================\"
        echo \"\\\\connect \\\"$ADMIN_DB\\\"\"
        echo \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '\$db' AND pid <> pg_backend_pid();\"
        echo \"DROP DATABASE IF EXISTS \\\"\$db\\\";\"
        echo \"CREATE DATABASE \\\"\$db\\\" OWNER \\\"$USER_BD\\\";\"
        echo \"\\\\connect \\\"\$db\\\"\"

        pg_dump -U \"$USER_BD\" -d \"\$db\" --format=plain --no-owner --no-privileges
      done
    } | gzip -9 > \"\$tmp\"

    test -s \"\$tmp\"
    mv -f \"\$tmp\" '$OUT_FILE'
  "

  log INFO "OK  : backup créé: $OUT_FILE"
fi

log INFO "PURGE: fichiers > ${KEEP_DAYS} jours"
docker exec "$CID" sh -c "
  set -e
  test -d '$OUT_DIR' || exit 3
  find '$OUT_DIR' -type f -name 'CLUSTER-*.sql.gz' -mtime +$KEEP_DAYS -print -delete
" || true

log INFO "=== END BACKUP DAILY CLUSTER ==="
log INFO "OK"
