#!/bin/bash
# Installe External Secrets Operator (ESO) sur le cluster Kubernetes.
#
# ESO est un opérateur cluster-wide qui synchronise automatiquement les secrets
# depuis un gestionnaire externe (Infisical, HashiCorp Vault, AWS SM, Azure KV…)
# vers des Kubernetes Secrets natifs. Il est installé dans son propre namespace
# "external-secrets", séparé du namespace applicatif "iam-system".
#
# À exécuter UNE SEULE FOIS avant deploy-infra.sh.
# Idempotent — safe à relancer si la version change.
#
# Usage:
#   ./scripts/setup-eso.sh

set -euo pipefail

ESO_VERSION="v0.10.7"
ESO_NAMESPACE="external-secrets"
ESO_INSTALL_URL="https://github.com/external-secrets/external-secrets/releases/download/${ESO_VERSION}/install.yaml"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# -------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-$PROJECT_ROOT/log/deploy}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/setup-eso_$(date '+%Y-%m-%d_%H-%M-%S').log}"
mkdir -p "$LOG_DIR" || { echo "ERREUR: impossible de créer LOG_DIR=$LOG_DIR"; exit 1; }
ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) - $*" | tee -a "$LOG_FILE"; }

# -------------------------------------------------------------------
# Prérequis
# -------------------------------------------------------------------
command -v kubectl >/dev/null 2>&1 || { log "ERREUR: kubectl introuvable"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { log "ERREUR: cluster inaccessible"; exit 1; }

# -------------------------------------------------------------------
# Installation ESO
# -------------------------------------------------------------------
log "=== INSTALLATION EXTERNAL SECRETS OPERATOR ==="
log "Version   : $ESO_VERSION"
log "Namespace : $ESO_NAMESPACE"
log "URL       : $ESO_INSTALL_URL"

log "Application des manifests ESO..."
kubectl apply -f "$ESO_INSTALL_URL" 2>&1 | tee -a "$LOG_FILE"

# -------------------------------------------------------------------
# Attente que l'opérateur soit prêt
# -------------------------------------------------------------------
log "Attente que les pods ESO soient prêts (max 120s)..."
kubectl wait --for=condition=available deployment \
  -l app.kubernetes.io/name=external-secrets \
  -n "$ESO_NAMESPACE" \
  --timeout=120s \
  2>&1 | tee -a "$LOG_FILE"

# -------------------------------------------------------------------
# Résumé
# -------------------------------------------------------------------
log "=== RÉSUMÉ ==="
kubectl get pods -n "$ESO_NAMESPACE" 2>&1 | tee -a "$LOG_FILE"
log "OK: ESO ${ESO_VERSION} installé et opérationnel."
log "Étape suivante : ./secrets/setup-infisical.sh --env <environnement>"
log "=== END SETUP ESO ==="
