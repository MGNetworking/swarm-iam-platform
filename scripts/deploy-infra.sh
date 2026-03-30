#!/bin/bash
# Déploiement HomeLab (Synology + Docker Swarm)
# - Charge environments/homeLab/.env
# - Appelle script/ensure-infra.sh (Docker ready + Swarm + réseaux overlay)
# - Déploie Traefik, Redis, PostgreSQL, Keycloak
# - Attend la stabilisation des services (replicas)
# - Probe Keycloak via Traefik
#
# Options:
#   --force   : réapplique docker stack deploy même si la stack existe déjà
#   --no-wait : ne pas attendre la stabilisation des replicas

set -euo pipefail

# -------------------------------------------------------------------
# Placement : se positionner à la racine du projet, quel que soit le cwd
# -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# -------------------------------------------------------------------
# Options CLI
# -------------------------------------------------------------------
FORCE_DEPLOY="false"
NO_WAIT="false"

for arg in "$@"; do
  case "$arg" in
    --force) FORCE_DEPLOY="true" ;;
    --no-wait) NO_WAIT="true" ;;
    -h|--help)
      cat <<EOF
Usage: ./script/deploy-infra.sh [--force] [--no-wait]

--force   : réapplique docker stack deploy même si la stack existe déjà
--no-wait : ne pas attendre la stabilisation des services
EOF
      exit 0
      ;;
    *)
      echo "Option inconnue: $arg" >&2
      exit 2
      ;;
  esac
done

# ===================================================================
# Chargement des fichiers .env
# ===================================================================

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
  echo "SOURCING: $CONF_FILE"
done
set +a

# -------------------------------------------------------------------
# Paramètres
# -------------------------------------------------------------------

ENSURE_INFRA_SCRIPT="$PROJECT_ROOT/scripts/ensure-infra.sh"
ENSURE_BACKUP_DIRS_SCRIPT="$PROJECT_ROOT/scripts/ensure-backup-dirs.sh"
MAX_WAIT="${MAX_WAIT:-420}"
WAIT_INTERVAL="${WAIT_INTERVAL:-10}"

# -------------------------------------------------------------------
# Logging (serveur) : fichier + terminal
# -------------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/tmp}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/deploy-infra.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}" # 10 MiB

mkdir -p "$LOG_DIR" || { echo "ERREUR: impossible de créer LOG_DIR=$LOG_DIR"; exit 1; }

rotate_log_if_needed() {
  if [ -f "$LOG_FILE" ]; then
    local size
    size="$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
    if [ "$size" -ge "$LOG_MAX_BYTES" ] 2>/dev/null; then
      mv -f "$LOG_FILE" "${LOG_FILE}.1" >/dev/null 2>&1 || true
    fi
  fi
}

rotate_log_if_needed

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(ts) - $*" | tee -a "$LOG_FILE"; }
die() { log "ERREUR: $*"; exit 1; }

on_error() {
  local exit_code=$?
  log "ERREUR: commande échouée (exit=$exit_code) à la ligne $1: $2"
  exit "$exit_code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# -------------------------------------------------------------------
# Variables attendues
# -------------------------------------------------------------------
: "${PG_STACK_NAME:?PG_STACK_NAME manquant dans le fichier .env}"
: "${KC_STACK_NAME:?KC_STACK_NAME manquant dans le fichier .env}"
: "${REDIS_STACK_NAME:?REDIS_STACK_NAME manquant dans le fichier .env}"
: "${KEYCLOAK_HOSTNAME:?KEYCLOAK_HOSTNAME manquant dans le fichier .env}"
: "${TRAEFIK_STACK_NAME:?TRAEFIK_STACK_NAME manquant dans le fichier .env}"
: "${TRAEFIK_PORT_INTERNAL:?TRAEFIK_PORT_INTERNAL manquant dans le fichier .env}"

: "${TRAEFIK_YML:?Variable TRAEFIK_YML manquante dans le fichier config.env}"
: "${REDIS_YML:?Variable REDIS_YML manquante dans le fichier config.env}"
: "${POSTGRES_YML:?Variable POSTGRES_YML manquante dans le fichier config.env}"
: "${KEYCLOAK_YML:?Variable KEYCLOAK_YML manquante dans le fichier config.env}"

# -------------------------------------------------------------------
# Fonctions Swarm / Stacks
# -------------------------------------------------------------------
stack_exists() {
  docker stack ls --format '{{.Name}}' | grep -q "^$1$"
}

deploy_stack() {
  local stack="$1"
  local yml="$2"

  if stack_exists "$stack"; then
    if [ "$FORCE_DEPLOY" = "true" ]; then
      log "Stack existante -> --force activé : réapplication stack: $stack (fichier: $yml)"

      docker service ps $stack --no-trunc | tee -a "$LOG_FILE" || true
      docker service logs $stack --tail 200 | tee -a "$LOG_FILE" || true
      docker stack deploy -c "$yml" "$stack" 2>&1 | tee -a "$LOG_FILE"

    else
      log "Stack déjà déployée: $stack (skip)"
    fi
    return 0
  fi

  log "Déploiement stack: $stack (fichier: $yml)"
  docker stack deploy -c "$yml" "$stack" 2>&1 | tee -a "$LOG_FILE"

}

wait_replicas_stable() {
  local service="$1"
  local timeout="${2:-180}"
  local elapsed=0

  if [ "$NO_WAIT" = "true" ]; then
    log "NO_WAIT=true -> skip stabilisation replicas pour: $service"
    return 0
  fi

  log "Attente stabilisation service: $service (timeout=${timeout}s)"
  while [ "$elapsed" -lt "$timeout" ]; do
    local replicas
    replicas="$(docker service ls --filter "name=$service" --format "{{.Replicas}}" 2>/dev/null || true)"

    if echo "$replicas" | grep -qE '^[0-9]+/[0-9]+$'; then
      local running="${replicas%/*}"
      local desired="${replicas#*/}"
      if [ "$desired" -gt 0 ] && [ "$running" -eq "$desired" ]; then
        log "Service stable: $service ($replicas)"
        return 0
      fi
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  log "ATTENTION: service non stable après ${timeout}s : $service"
  return 1
}

probe_keycloak_via_traefik() {
  command -v curl >/dev/null 2>&1 || return 2
  curl -fsS -H "Host: ${KEYCLOAK_HOSTNAME}" \
    "http://127.0.0.1:${TRAEFIK_PORT_INTERNAL}/realms/master" >/dev/null
}

# -------------------------------------------------------------------
# Exécution
# -------------------------------------------------------------------
log "=== DÉPLOIEMENT HOMELAB (Swarm) ==="
log "LOG_FILE=$LOG_FILE"
log "Configuration:"
log "  PROJECT_ROOT          : $PROJECT_ROOT"
log "  ENV_DIR               : $ENV_DIR"
log "  ENV_FILES             : ${ENV_FILES[*]}"
log "  FORCE_DEPLOY          : $FORCE_DEPLOY"
log "  NO_WAIT               : $NO_WAIT"
log "  TRAEFIK_STACK_NAME    : $TRAEFIK_STACK_NAME"
log "  PG_STACK_NAME         : $PG_STACK_NAME"
log "  REDIS_STACK_NAME      : $REDIS_STACK_NAME"
log "  KC_STACK_NAME         : $KC_STACK_NAME"
log "  KEYCLOAK_HOSTNAME     : $KEYCLOAK_HOSTNAME"
log "  TRAEFIK_PORT_INTERNAL : $TRAEFIK_PORT_INTERNAL"
log "  MAX_WAIT              : $MAX_WAIT"
log "  WAIT_INTERVAL         : $WAIT_INTERVAL"

# 1) Ensure infra (Docker ready + Swarm + réseaux overlay)
log "=== ENSURE INFRA (Docker/Swarm/Réseaux) ==="
chmod +x "$ENSURE_INFRA_SCRIPT" || true
"$ENSURE_INFRA_SCRIPT"

# 2) Ensure backup dirs (hôte)
log "=== ENSURE BACKUP DIRS (hôte) ==="
[ -f "$ENSURE_BACKUP_DIRS_SCRIPT" ] || die "Script introuvable: $ENSURE_BACKUP_DIRS_SCRIPT"
chmod +x "$ENSURE_BACKUP_DIRS_SCRIPT" || true
"$ENSURE_BACKUP_DIRS_SCRIPT"

# 3) Déploiement des stacks (ordre logique)
log "=== DÉPLOIEMENT TRAEFIK (interne) ==="
deploy_stack "$TRAEFIK_STACK_NAME" "$ENV_DIR/$TRAEFIK_YML"
wait_replicas_stable "${TRAEFIK_STACK_NAME}_traefik" 180 || true

log "=== DÉPLOIEMENT REDIS ==="
deploy_stack "$REDIS_STACK_NAME" "$ENV_DIR/$REDIS_YML"
wait_replicas_stable "${REDIS_STACK_NAME}_redis-shared" 180 || true

log "=== DÉPLOIEMENT POSTGRESQL ==="
deploy_stack "$PG_STACK_NAME" "$ENV_DIR/$POSTGRES_YML"
wait_replicas_stable "${PG_STACK_NAME}_postgres-shared" 240 || true

log "=== DÉPLOIEMENT KEYCLOAK ==="
deploy_stack "$KC_STACK_NAME" "$ENV_DIR/$KEYCLOAK_YML"
wait_replicas_stable "${KC_STACK_NAME}_keycloak" 300 || true

# 3) Probe
log "=== TEST ROUTAGE KEYCLOAK VIA TRAEFIK ==="
if probe_keycloak_via_traefik; then
  log "OK: Keycloak accessible via Traefik -> http://127.0.0.1:${TRAEFIK_PORT_INTERNAL} + Host:${KEYCLOAK_HOSTNAME}"
else
  rc=$?
  if [ "$rc" -eq 2 ]; then
    log "INFO: curl absent, test HTTP Keycloak ignoré."
  else
    log "ATTENTION: Keycloak non joignable via Traefik pour l'instant."
    log "  Pistes: Traefik pas prêt / labels Host incorrects / réseaux edge non raccordés / démarrage Keycloak long"
  fi
fi

# 4) Résumé
log "=== RÉSUMÉ ==="
docker stack ls || true
echo ""
docker service ls || true
log "Fin."
