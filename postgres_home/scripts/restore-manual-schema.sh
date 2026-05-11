#!/bin/bash
# Restauration du schéma (structure uniquement) depuis backup-manual.sh (mode "schéma")
# Fichier attendu : <db_name>-schema-YYYY-MM-DD_HHmmss.sql.gz
#
# Ce script restaure la STRUCTURE de la base (tables, index, contraintes, etc.)
# sans les données. La base est recréée proprement avant l'import.
#
# ATTENTION (destructif) :
# - Arrête Keycloak (scale=0)
# - DROP + CREATE de la base ciblée (perte des données existantes)
# - Applique le dump de schéma (recrée la structure)
# - Relance Keycloak (scale=1)
#
# Cas d'usage typique : restaurer la structure après une mauvaise migration
# en préparant une base vide prête à être repopulée.
#
# Usage:
#   ./postgres_home/scripts/restore-manual-schema.sh --env <env> <backup_file.sql.gz>
#
# Exemple:
#   ./postgres_home/scripts/restore-manual-schema.sh --env linux-server kc_db-schema-2025-12-28_143000.sql.gz

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
  ./postgres_home/scripts/restore-manual-schema.sh --env <env> <backup_file.sql.gz>

Format du fichier (produit par backup-manual.sh en mode schéma) :
  <db_name>-schema-YYYY-MM-DD_HHmmss.sql.gz

Exemple:
  ./postgres_home/scripts/restore-manual-schema.sh --env linux-server kc_db-schema-2025-12-28_143000.sql.gz

ATTENTION (destructif) : DROP + CREATE de la base, puis restauration de la structure uniquement.
Les données existantes seront perdues.
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
: "${DB_NAME:?DB_NAME manquant dans .env}"
: "${LOG_DIR:?LOG_DIR manquant dans config.env}"

NAMESPACE="${NAMESPACE:-iam-system}"
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
# Validation du fichier et extraction du nom de base
# -------------------------------------------------------------------
[[ "$BACKUP_FILE" == *.sql.gz ]] || die "Le fichier doit se terminer par .sql.gz"

base="${BACKUP_FILE%.sql.gz}"
# Format attendu: kc_db-schema-2025-12-28_143000 → extrait "kc_db"
if [[ "$base" =~ ^([a-zA-Z0-9_]+)-schema-[0-9]{4} ]]; then
  DB_NAME_FROM_FILE="${BASH_REMATCH[1]}"
else
  die "Format de fichier non reconnu: '$BACKUP_FILE'
Format attendu : <db_name>-schema-YYYY-MM-DD_HHmmss.sql.gz
Exemple        : kc_db-schema-2025-12-28_143000.sql.gz"
fi

[[ "$DB_NAME_FROM_FILE" =~ ^[a-zA-Z0-9_]+$ ]] || \
  die "Nom de DB invalide extrait: '$DB_NAME_FROM_FILE'"
[[ "$DB_NAME_FROM_FILE" == "$DB_NAME" ]] || \
  die "Incohérence: DB du fichier='$DB_NAME_FROM_FILE' / DB_NAME env='$DB_NAME' — vérifiez le bon fichier."

BACKUP_PATH="$PROJECT_ROOT/postgres_home/backups/manual/schema/$BACKUP_FILE"
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
log INFO "=== START RESTORE SCHEMA (MANUAL) ==="
log INFO "ENV       : $ENV_NAME"
log INFO "Namespace : $NAMESPACE"
log INFO "Pod PG    : $PG_POD"
log INFO "DB        : $DB_NAME"
log INFO "Backup    : $BACKUP_PATH"
log INFO "User      : $USER_BD"

echo ""
echo "ATTENTION : cette opération va DROPPER puis RECRÉER la base '$DB_NAME'."
echo "Seule la structure sera restaurée — les données existantes seront perdues."
read -r -p "Tapez EXACTEMENT 'RESTORE-SCHEMA' pour continuer: " confirm
[ "$confirm" = "RESTORE-SCHEMA" ] || die "Opération annulée par l'utilisateur."
log INFO "Confirmation utilisateur: OK"

# 1) Arrêt Keycloak
stop_keycloak

# 2) DROP / CREATE la base (repart d'une base propre)
log INFO "DROP / CREATE DB: $DB_NAME..."
kubectl exec -n "$NAMESPACE" "$PG_POD" -- sh -c "
  set -e
  export PGPASSWORD=\"\$POSTGRES_PASSWORD\"

  # Ferme les connexions actives sur la base cible avant de la supprimer
  psql -U \"\$POSTGRES_USER\" -d postgres -v ON_ERROR_STOP=1 -c \
    \"SELECT pg_terminate_backend(pid)
     FROM pg_stat_activity
     WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();\" || true

  psql -U \"\$POSTGRES_USER\" -d postgres -v ON_ERROR_STOP=1 \
    -c \"DROP DATABASE IF EXISTS \\\"${DB_NAME}\\\";\"

  psql -U \"\$POSTGRES_USER\" -d postgres -v ON_ERROR_STOP=1 \
    -c \"CREATE DATABASE \\\"${DB_NAME}\\\";\"
"

# 3) Restauration du schéma (pipe gzip → psql dans le pod)
log INFO "RESTORE SCHÉMA en cours..."
gzip -dc "$BACKUP_PATH" | \
  kubectl exec -i -n "$NAMESPACE" "$PG_POD" -- \
    sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d '"\"${DB_NAME}\""' -v ON_ERROR_STOP=1'

log INFO "OK: schéma restauré — la base '$DB_NAME' est vide (structure seule)."

# 4) Relance Keycloak
start_keycloak

log INFO "=== END RESTORE SCHEMA (MANUAL) ==="
