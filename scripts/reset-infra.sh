#!/bin/bash
# Réinitialisation destructive de la plateforme IAM k3s
# Supprime le namespace iam-system et toutes ses ressources (pods, PVCs, secrets, etc.)
#
# ATTENTION: cette opération est irréversible. Les données persistantes seront perdues.
#
# Usage:
#   ./scripts/reset-infra.sh --env <linux-server|cloud/azure|cloud/aws>
#   ./scripts/reset-infra.sh --env linux-server --yes          # sans confirmation
#   ./scripts/reset-infra.sh --env linux-server --keep-data    # conserve les PVCs

set -euo pipefail

# -------------------------------------------------------------------
# Placement : racine du projet
# -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# -------------------------------------------------------------------
# Options CLI
# -------------------------------------------------------------------
ENV_NAME=""
YES="false"
KEEP_DATA="false"

while [ "${1:-}" != "" ]; do
  case "$1" in
    --env)
      shift
      [ -n "${1:-}" ] || { echo "ERREUR: --env attend une valeur" >&2; exit 2; }
      ENV_NAME="$1"
      shift
      ;;
    --yes)       YES="true";       shift ;;
    --keep-data) KEEP_DATA="true"; shift ;;
    -h|--help)
      cat <<EOF
Usage: ./scripts/reset-infra.sh --env <environnement> [options]

Options:
  --yes         Pas de confirmation interactive
  --keep-data   Conserve les PersistentVolumeClaims (données PostgreSQL et Redis)
  -h, --help    Afficher cette aide

ATTENTION: opération irréversible sans --keep-data.
EOF
      exit 0
      ;;
    *) echo "Option inconnue: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ENV_NAME" ] || { echo "ERREUR: --env est obligatoire" >&2; exit 2; }

# -------------------------------------------------------------------
# Chargement .env
# -------------------------------------------------------------------
ENV_DIR="$PROJECT_ROOT/environments/$ENV_NAME"
[ -d "$ENV_DIR" ] || { echo "ERREUR: environnement introuvable: $ENV_DIR" >&2; exit 1; }

shopt -s nullglob
ENV_FILES=("$ENV_DIR/.env" "$ENV_DIR"/*.env)
shopt -u nullglob

set -a
for CONF_FILE in "${ENV_FILES[@]}"; do
  # shellcheck source=/dev/null
  source "$CONF_FILE"
done
set +a

NAMESPACE="${NAMESPACE:-iam-system}"

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) - $*"; }
die() { log "ERREUR: $*"; exit 1; }

# -------------------------------------------------------------------
# Vérifications avant reset
# -------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || die "kubectl introuvable."
kubectl cluster-info >/dev/null 2>&1 || die "Cluster k3s inaccessible."

echo ""
echo "=== RESET INFRA (k3s) ==="
echo "ENV       : $ENV_NAME"
echo "NAMESPACE : $NAMESPACE"
echo "KEEP_DATA : $KEEP_DATA"
echo ""
echo "Ressources actuelles dans $NAMESPACE :"
kubectl get all -n "$NAMESPACE" 2>/dev/null || echo "  (namespace vide ou absent)"
echo ""
echo "PersistentVolumeClaims :"
kubectl get pvc -n "$NAMESPACE" 2>/dev/null || echo "  (aucun)"
echo ""

if [ "$YES" != "true" ]; then
  echo "ATTENTION: cette opération va supprimer le namespace '$NAMESPACE' et toutes ses ressources."
  [ "$KEEP_DATA" = "true" ] && echo "         : les PVCs seront conservés (--keep-data)."
  [ "$KEEP_DATA" != "true" ] && echo "         : les PVCs (données) seront SUPPRIMÉS."
  echo ""
  read -r -p "Tapez EXACTEMENT 'RESET-INFRA' pour continuer: " confirm
  [ "$confirm" = "RESET-INFRA" ] || { echo "Annulé."; exit 1; }
fi

# -------------------------------------------------------------------
# Sauvegarde des PVCs si --keep-data
# -------------------------------------------------------------------
if [ "$KEEP_DATA" = "true" ]; then
  log "Sauvegarde des PVCs (keep-data)..."
  kubectl get pvc -n "$NAMESPACE" -o yaml > /tmp/pvcs-backup-"$NAMESPACE".yaml 2>/dev/null || true
  log "PVCs sauvegardés dans /tmp/pvcs-backup-$NAMESPACE.yaml"
fi

# -------------------------------------------------------------------
# Suppression du namespace
# -------------------------------------------------------------------
log "Suppression du namespace: $NAMESPACE"
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  kubectl delete namespace "$NAMESPACE" --timeout=120s 2>&1 || {
    log "ATTENTION: timeout lors de la suppression, forçage..."
    kubectl delete namespace "$NAMESPACE" --grace-period=0 --force 2>&1 || true
  }
  log "Namespace $NAMESPACE supprimé."
else
  log "Namespace $NAMESPACE déjà absent."
fi

# -------------------------------------------------------------------
# Restauration des PVCs si --keep-data
# -------------------------------------------------------------------
if [ "$KEEP_DATA" = "true" ] && [ -f /tmp/pvcs-backup-"$NAMESPACE".yaml ]; then
  log "Recréation namespace pour restaurer les PVCs..."
  kubectl create namespace "$NAMESPACE" 2>/dev/null || true
  kubectl apply -f /tmp/pvcs-backup-"$NAMESPACE".yaml 2>/dev/null || true
  log "PVCs restaurés."
fi

echo ""
echo "=== RÉSUMÉ ==="
kubectl get namespace "$NAMESPACE" 2>/dev/null || echo "Namespace $NAMESPACE absent (reset OK)."
echo "OK: reset infra terminé."
