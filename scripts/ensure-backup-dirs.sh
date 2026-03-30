#!/bin/bash
# Crée les dossiers de backups sur l'hôte (NAS), une seule fois.
# Objectif: éviter tout mkdir dans les scripts de backup exécutés via docker exec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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

: "${LOG_DIR:?LOG_DIR manquant dans config.env}"

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

log INFO "=== START ENSURE BACKUP DIRS ==="
log INFO "Script dir   : $SCRIPT_DIR"
log INFO "Project root : $PROJECT_ROOT"
log INFO "Env dir      : $ENV_DIR"
log INFO "Env files    : ${ENV_FILES[*]}"
log INFO "Log file     : $LOG_FILE"

# =========================
# Dossiers backups
# =========================
BASE_DIR="$PROJECT_ROOT/postgres_home/backups"

DIRS=(
  "$BASE_DIR/daily/cluster"
  "$BASE_DIR/manual/BD"
  "$BASE_DIR/manual/schema"
)

log INFO "Base backups : $BASE_DIR"

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
