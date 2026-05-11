#!/bin/bash
# Vérifie que les secrets Kubernetes requis existent dans le namespace iam-system
# Ne crée rien, ne modifie rien.
#
# Usage:
#   ./secrets/check-secrets.sh [--env <linux-server|cloud/azure|cloud/aws>] [--list]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# -------------------------------------------------------------------
# Options CLI
# -------------------------------------------------------------------
ENV_NAME=""
LIST="false"

while [ "${1:-}" != "" ]; do
  case "$1" in
    --env)
      shift
      [ -n "${1:-}" ] || { echo "ERREUR: --env attend une valeur" >&2; exit 2; }
      ENV_NAME="$1"
      shift
      ;;
    --list) LIST="true"; shift ;;
    -h|--help)
      cat <<EOF
Usage: ./secrets/check-secrets.sh [--env <environnement>] [--list]

--env   Charge le namespace depuis environments/<env>/.env
--list  Affiche tous les secrets K8s présents dans le namespace
EOF
      exit 0
      ;;
    *) echo "Option inconnue: $1" >&2; exit 2 ;;
  esac
done

# -------------------------------------------------------------------
# Namespace (depuis .env ou valeur par défaut)
# -------------------------------------------------------------------
NAMESPACE="iam-system"

if [ -n "$ENV_NAME" ]; then
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
fi

# -------------------------------------------------------------------
# Vérifications préalables
# -------------------------------------------------------------------
MANIFEST="$PROJECT_ROOT/secrets/secrets.manifest"
[ -f "$MANIFEST" ] || { echo "ERREUR: secrets.manifest introuvable: $MANIFEST"; exit 1; }

command -v kubectl >/dev/null 2>&1 || { echo "ERREUR: kubectl introuvable"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "ERREUR: cluster k3s inaccessible"; exit 1; }

echo "=== CHECK SECRETS KUBERNETES ==="
echo "Namespace : $NAMESPACE"
echo "Manifest  : $MANIFEST"
echo ""

if [ "$LIST" = "true" ]; then
  echo "=== Secrets présents dans $NAMESPACE ==="
  kubectl get secrets -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1}' | sort || true
  echo ""
fi

# -------------------------------------------------------------------
# Vérification de chaque secret/clé du manifest
# -------------------------------------------------------------------
missing=0

echo "=== Vérification manifest ==="
while IFS= read -r line; do
  name="$(echo "$line" | xargs)"
  [ -z "$name" ] && continue
  [[ "$name" == \#* ]] && continue

  secret_name="${name%%/*}"
  secret_key="${name##*/}"

  if kubectl get secret "$secret_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    if kubectl get secret "$secret_name" -n "$NAMESPACE" \
        -o jsonpath="{.data.$secret_key}" 2>/dev/null | grep -q .; then
      echo "OK      : $secret_name ($secret_key)"
    else
      echo "MISSING : $secret_name -> clé '$secret_key' absente"
      missing=1
    fi
  else
    echo "MISSING : $secret_name (secret inexistant)"
    missing=1
  fi
done < "$MANIFEST"

echo ""
if [ "$missing" -eq 0 ]; then
  echo "OK: tous les secrets requis sont présents."
  exit 0
fi

echo "ERREUR: secrets manquants. Créez-les avec kubectl :"
echo "  kubectl create secret generic pg-password --from-literal=password='...' -n $NAMESPACE"
echo "  kubectl create secret generic redis-password --from-literal=password='...' -n $NAMESPACE"
echo "  kubectl create secret generic keycloak-admin --from-literal=password='...' -n $NAMESPACE"
exit 1
