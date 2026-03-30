#!/bin/bash
# Backup manuel interactif:
# - Choix: (1) BD complète  (2) Schema-only
# - Sélection par numéros

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
: "${LOG_DIR:?LOG_DIR manquant (attendu dans config.env ou .env)}"
: "${USER_BD:?USER_BD manquant dans .env (ex: max_admin)}"
: "${DB_NAME:?DB_NAME manquant dans .env (ex: kc_db)}"

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

# Tout stdout/stderr -> console + fichier (append)
exec > >(tee -a "$LOG_FILE") 2>&1

# En cas d'erreur, log + exit code
# shellcheck disable=SC2154
trap 'rc=$?; log ERROR "Échec (rc=$rc) à la ligne $LINENO"; exit $rc' ERR

log INFO "=== START BACKUP MANUEL POSTGRES ==="
log INFO "Project root : $PROJECT_ROOT"
log INFO "Env dir      : $ENV_DIR"
log INFO "Env files    : ${ENV_FILES[*]}"
log INFO "Log file     : $LOG_FILE"

SERVICE="${PG_STACK_NAME}_postgres-shared"
CONTAINER_ID="$(docker ps --filter "name=${SERVICE}" -q | head -n1)"
[ -n "$CONTAINER_ID" ] || { log ERROR "Conteneur Postgres introuvable (service=$SERVICE)"; exit 1; }

OUT_DB_DIR="/var/backups/manual/BD"
OUT_SCHEMA_DIR="/var/backups/manual/schema"
TS="$(date +%Y-%m-%d_%H-%M-%S)"

die() { log ERROR "$*"; exit 1; }

require_dirs() {
  docker exec "$CONTAINER_ID" sh -c "
    test -d '$OUT_DB_DIR' || exit 11
    test -d '$OUT_SCHEMA_DIR' || exit 12
  " >/dev/null 2>&1 || die "Dossiers backups absents dans le conteneur. Lancez d'abord: script/ensure-backup-dirs.sh (et vérifiez le mount /var/backups)."
}

# Wrapper: exécuter psql dans le conteneur avec secret password
psql_in_container() {
  # args passés tels quels à psql
  docker exec "$CONTAINER_ID" sh -c "
    export PGPASSWORD=\"\$(cat /run/secrets/pg_password)\"
    psql -U \"$USER_BD\" $*
  "
}

# Liste des DB (hors templates) -> tableau bash
list_databases() {
  docker exec "$CONTAINER_ID" sh -c "
    export PGPASSWORD=\"\$(cat /run/secrets/pg_password)\"
    psql -U \"$USER_BD\" -d \"$DB_NAME\" -Atc \"SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;\"
  "
}

# Liste des schemas d'une DB (hors schemas système)
list_schemas() {
  local db="$1"
  docker exec "$CONTAINER_ID" sh -c "
    export PGPASSWORD=\"\$(cat /run/secrets/pg_password)\"
    psql -U \"$USER_BD\" -d '$db' -Atc \"
      SELECT nspname
      FROM pg_namespace
      WHERE nspname NOT IN ('pg_catalog','information_schema')
        AND nspname NOT LIKE 'pg_toast%'
        AND nspname NOT LIKE 'pg_temp_%'
      ORDER BY nspname;
    \"
  "
}

choose_from_list() {
  # args: title, list...
  local title="$1"; shift
  local -a items=("$@")
  local n="${#items[@]}"

  [ "$n" -gt 0 ] || die "Liste vide: $title"

  # IMPORTANT:
  # - Tout l'affichage (menu) sur STDERR (>&2)
  # - Seul le choix final sur STDOUT (capturable dans une variable)
  echo "" >&2
  echo "=== $title ===" >&2

  local i
  for i in "${!items[@]}"; do
    printf "  %2d) %s\n" "$((i+1))" "${items[$i]}" >&2
  done

  echo "" >&2

  local choice
  while true; do
    read -r -p "Choisissez un numéro (1-$n): " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { echo "Entrée invalide." >&2; continue; }
    [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ] || { echo "Hors plage." >&2; continue; }
    printf "%s" "${items[$((choice-1))]}"   # <-- uniquement le texte choisi sur stdout
    return 0
  done
}

log INFO "Service   : $SERVICE"
log INFO "Container : $CONTAINER_ID"
log INFO "Timestamp : $TS"
log INFO "DB_NAME   : $DB_NAME"
log INFO "USER_BD   : $USER_BD"

require_dirs

echo ""
echo "Que voulez-vous sauvegarder ?"
echo "  1) BD complète (schéma + données)"
echo "  2) Schema-only (un schema d'une BD)"
echo ""

mode=""
while true; do
  read -r -p "Votre choix (1-2): " mode
  case "$mode" in
    1|2) break ;;
    *) echo "Entrée invalide." ;;
  esac
done
log INFO "Mode choisi : $mode"

# Charger DBs (avec diagnostic clair si auth/connexion échoue)
if ! DBS_RAW="$(list_databases)"; then
  die "Impossible de lister les bases. Vérifiez USER_BD='$USER_BD' et le secret /run/secrets/pg_password."
fi

mapfile -t DBS <<< "$DBS_RAW"
[ "${#DBS[@]}" -gt 0 ] || die "Aucune base trouvée (après connexion OK)."
log INFO "Bases détectées (${#DBS[@]}) : ${DBS[*]}"
log INFO "Sélection de la base à sauvegarder..."

if [ "$mode" = "1" ]; then
  db="$(choose_from_list "Sélection de la base" "${DBS[@]}")"
  out="${OUT_DB_DIR}/DB-${TS}-${db}.sql.gz"

  log INFO "BACKUP DB   : $db"
  log INFO "OUT         : $out"

  docker exec "$CONTAINER_ID" sh -c "
    export PGPASSWORD=\"\$(cat /run/secrets/pg_password)\"
    pg_dump -U \"$USER_BD\" -d '$db' | gzip -9 > '$out'
  "

  log INFO "OK: backup DB terminé."
  log INFO "=== END BACKUP MANUEL POSTGRES ==="
  exit 0
fi

# mode 2: schema-only
db="$(choose_from_list "Sélection de la base (pour lister ses schemas)" "${DBS[@]}")"
log INFO "DB choisie  : $db"

if ! SCHEMAS_RAW="$(list_schemas "$db")"; then
  die "Impossible de lister les schemas de '$db'. Vérifiez les droits de USER_BD='$USER_BD'."
fi

mapfile -t SCHEMAS <<< "$SCHEMAS_RAW"
[ "${#SCHEMAS[@]}" -gt 0 ] || die "Aucun schema utilisateur trouvé dans la base '$db'."
log INFO "Schemas count: ${#SCHEMAS[@]}"

schema="$(choose_from_list "Sélection du schema (DB: $db)" "${SCHEMAS[@]}")"
out="${OUT_SCHEMA_DIR}/SCHEMA-${TS}-${db}__${schema}.sql.gz"

log INFO "BACKUP SCHEMA: ${db}.${schema}"
log INFO "OUT          : $out"

docker exec "$CONTAINER_ID" sh -c "
  export PGPASSWORD=\"\$(cat /run/secrets/pg_password)\"
  pg_dump -U \"$USER_BD\" -d '$db' --schema='$schema' | gzip -9 > '$out'
"

log INFO "OK: backup schema terminé."
log INFO "=== END BACKUP MANUEL POSTGRES ==="