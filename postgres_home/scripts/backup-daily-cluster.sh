#!/bin/bash
# Backup quotidien du cluster PostgreSQL via kubectl exec
# - 1 fichier par jour (CLUSTER-YYYY-MM-DD.sql.gz)
# - Purge automatique des fichiers > 30 jours
#
# Restore depuis ce fichier :
#   gzip -dc CLUSTER-YYYY-MM-DD.sql.gz | \
#     kubectl exec -i -n iam-system <pod> -- \
#       sh -c 'psql -U "$POSTGRES_USER" -d postgres'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

# -------------------------------------------------------------------
# Chargement .env (linux-server par défaut)
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

# -------------------------------------------------------------------
# Variables requises
# -------------------------------------------------------------------
: "${USER_BD:?USER_BD manquant dans .env}"
: "${LOG_DIR:?LOG_DIR manquant dans config.env}"

NAMESPACE="${NAMESPACE:-iam-system}"
KEEP_DAYS="${PG_BACKUP_KEEP_DAYS:-30}"

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0" .sh)"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
mkdir -p "$LOG_DIR"

log() { local level="$1"; shift; echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"; }
exec > >(tee -a "$LOG_FILE") 2>&1
trap 'rc=$?; log ERROR "Échec (rc=$rc) à la ligne $LINENO"; exit $rc' ERR

# -------------------------------------------------------------------
# Trouver le pod PostgreSQL
# -------------------------------------------------------------------
PG_POD="$(kubectl get pod -n "$NAMESPACE" \
  -l app.kubernetes.io/name=postgresql \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" \
  || { log ERROR "Pod PostgreSQL introuvable dans $NAMESPACE"; exit 1; }
[ -n "$PG_POD" ] || { log ERROR "Pod PostgreSQL introuvable dans $NAMESPACE"; exit 1; }

# -------------------------------------------------------------------
# Répertoire de sortie (hôte)
# -------------------------------------------------------------------
OUT_DIR="$PROJECT_ROOT/postgres_home/backups/daily/cluster"
mkdir -p "$OUT_DIR"

DATE="$(date +%Y-%m-%d)"
OUT_FILE="${OUT_DIR}/CLUSTER-${DATE}.sql.gz"

log INFO "=== START BACKUP DAILY CLUSTER ==="
log INFO "Namespace   : $NAMESPACE"
log INFO "Pod         : $PG_POD"
log INFO "User        : $USER_BD"
log INFO "Output      : $OUT_FILE"
log INFO "Retention   : ${KEEP_DAYS} jours"

if [ -f "$OUT_FILE" ]; then
  log INFO "SKIP: backup déjà présent pour aujourd'hui: $OUT_FILE"
else
  log INFO "Génération du dump cluster..."
  TMP_FILE="${OUT_FILE}.tmp"

  kubectl exec -n "$NAMESPACE" "$PG_POD" -- \
    sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall -U "$POSTGRES_USER" --no-roles --clean' \
    | gzip -9 > "$TMP_FILE"

  [ -s "$TMP_FILE" ] || { log ERROR "Dump vide ou échec"; rm -f "$TMP_FILE"; exit 1; }
  mv -f "$TMP_FILE" "$OUT_FILE"
  log INFO "OK: backup créé: $OUT_FILE ($(du -sh "$OUT_FILE" | cut -f1))"
fi

# -------------------------------------------------------------------
# Purge des anciens backups
# -------------------------------------------------------------------
log INFO "Purge des fichiers > ${KEEP_DAYS} jours dans $OUT_DIR"
find "$OUT_DIR" -type f -name 'CLUSTER-*.sql.gz' -mtime +"$KEEP_DAYS" -print -delete || true

log INFO "=== END BACKUP DAILY CLUSTER ==="
