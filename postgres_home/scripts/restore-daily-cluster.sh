#!/bin/bash
# Restore daily: toutes les DB depuis un fichier unique CLUSTER-YYYY-MM-DD.sql.gz
# Produit par le backup daily "ONE FILE, NO ROLES".
#
# ATTENTION: destructif
# - DROP/CREATE de chaque DB contenue dans le fichier (sauf la DB admin)
# - stop/restart Keycloak (non destructif: scale 0 puis 1)

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

: "${LOG_DIR:?LOG_DIR manquant dans config.env}"
: "${PG_STACK_NAME:?PG_STACK_NAME manquant dans .env}"
: "${KC_STACK_NAME:?KC_STACK_NAME manquant dans .env}"
: "${USER_BD:?USER_BD manquant dans .env (ex: max_admin)}"

# DB "admin" utilisée par le fichier (doit matcher celle du backup)
ADMIN_DB="${ADMIN_DB:-postgres}"

# =========================
# Logging (hôte)
# =========================
SCRIPT_NAME="$(basename "$0" .sh)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
mkdir -p "$LOG_DIR"

log() { local level="$1"; shift; echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"; }
die() { log ERROR "$*"; exit 1; }

exec > >(tee -a "$LOG_FILE") 2>&1
# shellcheck disable=SC2154
trap 'rc=$?; log ERROR "Échec (rc=$rc) à la ligne $LINENO"; exit $rc' ERR

SERVICE="${PG_STACK_NAME}_postgres-shared"
BACKUP_DIR_HOST="$PROJECT_ROOT/postgres_home/backups/daily/cluster"

usage() {
  cat <<EOF
Usage:
  ./postgres_home/scripts/restore-daily-cluster.sh <CLUSTER-YYYY-MM-DD.sql.gz>

Exemple:
  ./postgres_home/scripts/restore-daily-cluster.sh CLUSTER-2025-12-28.sql.gz

Variables:
  ADMIN_DB=postgres (par défaut) : base admin utilisée pour DROP/CREATE

ATTENTION (destructif):
- stoppe Keycloak (stack $KC_STACK_NAME) (non destructif: scale=0)
- exécute le fichier sur la DB admin ($ADMIN_DB)
- relance Keycloak (scale=1)
EOF
}

BACKUP_FILE="${1:-}"
[ -n "$BACKUP_FILE" ] || { usage; exit 2; }

BACKUP_PATH_HOST="$BACKUP_DIR_HOST/$BACKUP_FILE"
[ -f "$BACKUP_PATH_HOST" ] || die "Backup introuvable: $BACKUP_PATH_HOST"

stop_stack() {
  local stack="$1"
  log INFO "STOP stack (non destructif): $stack"
  local services
  services="$(docker stack services "$stack" --format '{{.Name}}' 2>/dev/null || true)"
  if [ -z "$services" ]; then
    log INFO "INFO: stack absente ou aucun service: $stack"
    return 0
  fi
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    log INFO "SCALE: $svc=0"
    docker service scale "$svc=0" >/dev/null
  done <<< "$services"
}

start_stack() {
  local stack="$1"
  log INFO "START stack: $stack (scale=1 pour chaque service)"
  local services
  services="$(docker stack services "$stack" --format '{{.Name}}' 2>/dev/null || true)"
  if [ -z "$services" ]; then
    log INFO "INFO: stack absente ou aucun service: $stack"
    return 0
  fi
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    log INFO "SCALE: $svc=1"
    docker service scale "$svc=1" >/dev/null
  done <<< "$services"
}

wait_postgres_ready() {
  local timeout="${1:-180}"
  local elapsed=0
  log INFO "Attente Postgres prêt (timeout=${timeout}s)..." >&2
  while [ "$elapsed" -lt "$timeout" ]; do
    local cid
    cid="$(docker ps --filter "name=${SERVICE}" --filter "status=running" -q | head -n1 || true)"
    if [ -n "$cid" ]; then
      if docker exec "$cid" pg_isready -U "$USER_BD" -d "$ADMIN_DB" >/dev/null 2>&1; then
        log INFO "OK: Postgres répond (container=$cid)" >&2
        echo "$cid"
        return 0
      fi
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 1
}

log INFO "=== START RESTORE DAILY CLUSTER (ONE FILE) ==="
log INFO "Backup   : $BACKUP_PATH_HOST"
log INFO "User     : $USER_BD"
log INFO "Admin DB : $ADMIN_DB"
log INFO "Stack KC : $KC_STACK_NAME"
log INFO "Stack PG : $PG_STACK_NAME"

echo ""
echo "CONFIRMATION requise."
read -r -p "Confirmer le RESTORE COMPLET (toutes DB) depuis '$BACKUP_FILE' ? [y/N]: " confirm
case "${confirm,,}" in
  y|yes) log INFO "Confirmation utilisateur: OK" ;;
  *) die "Opération annulée par l'utilisateur." ;;
esac

# 1) Stop Keycloak
stop_stack "$KC_STACK_NAME"

# 2) Wait Postgres + CID
CID="$(wait_postgres_ready 240)" || die "Postgres non prêt (timeout)."
CID="$(echo "$CID" | tail -n1 | tr -d '\r\n')"
[[ "$CID" =~ ^[0-9a-f]{12,64}$ ]] || die "CID invalide capturé: '$CID'"
log INFO "Postgres container CID: $CID"

# 3) Vérifier que le fichier cible contient bien les \connect attendus (optionnel mais utile)
log INFO "Vérification rapide du dump (présence de '\\connect \"$ADMIN_DB\"')..."
if ! gzip -dc "$BACKUP_PATH_HOST" | head -n 50 | grep -q "\\\\connect \"$ADMIN_DB\""; then
  log INFO "WARN: la ligne \\connect \"$ADMIN_DB\" n'a pas été trouvée dans les 50 premières lignes."
  log INFO "WARN: si le backup a été généré avec une autre ADMIN_DB, exportez ADMIN_DB=<valeur> puis relancez."
fi

# 4) Restore: exécuter le fichier unique sur la DB admin
log INFO "RESTORE en cours (gzip -> psql -d $ADMIN_DB)..."
gzip -dc "$BACKUP_PATH_HOST" | docker exec -i "$CID" sh -c "
  set -e
  export PGPASSWORD=\"\$(cat /run/secrets/pg_password)\"
  psql -U \"$USER_BD\" -d \"$ADMIN_DB\" -v ON_ERROR_STOP=1
"

log INFO "OK: restore cluster (toutes DB) terminé."

# 5) Restart Keycloak
start_stack "$KC_STACK_NAME"

log INFO "=== END RESTORE DAILY CLUSTER ==="
