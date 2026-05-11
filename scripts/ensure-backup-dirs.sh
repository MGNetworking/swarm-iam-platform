#!/bin/bash
# Crée les dossiers de backups sur l'hôte, une seule fois.
# Idempotent — safe à relancer.
#
# Usage:
#   ./scripts/ensure-backup-dirs.sh --env <linux-server|cloud/azure|cloud/aws>

set -euo pipefail

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
      echo "Usage: ./scripts/ensure-backup-dirs.sh --env <linux-server|cloud/azure|cloud/aws>"
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

[ "${#ENV_FILES[@]}" -gt 0 ] || { echo "ERREUR: aucun fichier .env trouvé dans $ENV_DIR" >&2; exit 1; }

set -a
for CONF_FILE in "${ENV_FILES[@]}"; do
  # shellcheck source=/dev/null
  source "$CONF_FILE"
done
set +a

: "${LOG_DIR:?LOG_DIR manquant dans config.env}"

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0" .sh)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"

mkdir -p "$LOG_DIR"

log() {
  local level="$1"; shift
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
}

exec > >(tee -a "$LOG_FILE") 2>&1

# shellcheck disable=SC2154
trap 'rc=$?; log ERROR "Échec (rc=$rc) à la ligne $LINENO"; exit $rc' ERR

log INFO "=== START ENSURE BACKUP DIRS ==="
log INFO "ENV          : $ENV_NAME"
log INFO "Project root : $PROJECT_ROOT"
log INFO "Env dir      : $ENV_DIR"
log INFO "Log file     : $LOG_FILE"

# -------------------------------------------------------------------
# Dossiers backups
# -------------------------------------------------------------------
BASE_MANUAL="$PROJECT_ROOT/postgres_home/backups"

# Backups manuels — tous environnements
DIRS=(
  "$BASE_MANUAL/manual/BD"
  "$BASE_MANUAL/manual/schema"
)

# Backups daily — linux-server uniquement (hostPath CronJob k8s)
if [ "$ENV_NAME" = "linux-server" ]; then
  DIRS+=("/var/backups/postgresql")
fi

log INFO "Backups manual : $BASE_MANUAL/manual"
[ "$ENV_NAME" = "linux-server" ] && log INFO "Backups daily  : /var/backups/postgresql (hostPath)"

for d in "${DIRS[@]}"; do
  if [ -d "$d" ]; then
    log INFO "OK     : $d"
  else
    log INFO "CREATE : $d"
    mkdir -p "$d"
    log INFO "CREATED: $d"
  fi
done

log INFO "OK: dossiers de backups prêts."
log INFO "=== END ENSURE BACKUP DIRS ==="
