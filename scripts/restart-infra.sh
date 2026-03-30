#!/bin/bash
# Redémarrage contrôlé des services Docker Swarm après reboot Synology
# Objectif: "check & repair" : vérifier, attendre, relancer uniquement si nécessaire

set -euo pipefail

# =========================
# Placement : racine projet
# =========================
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

# =========================
# Paramètres
# =========================
MAX_WAIT="${MAX_WAIT:-420}"
WAIT_INTERVAL="${WAIT_INTERVAL:-10}"

# Endpoint interne Traefik (Nginx -> Traefik)
TRAEFIK_LOCAL_URL="http://127.0.0.1:${TRAEFIK_PORT_INTERNAL}/"

# =========================
# Configuration logs
# =========================
LOG_DIR="${LOG_DIR:-/tmp}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/restart-infra.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}" # 10 MiB

mkdir -p "$LOG_DIR" || { echo "ERREUR: impossible de créer LOG_DIR=$LOG_DIR"; exit 1; }

rotate_log_if_needed() {
  # Rotation simple: restart.log -> restart.log.1 si > LOG_MAX_BYTES
  if [ -f "$LOG_FILE" ]; then
    # BusyBox stat peut varier; on tente GNU, sinon BusyBox
    local size
    size="$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
    if [ "$size" -ge "$LOG_MAX_BYTES" ] 2>/dev/null; then
      mv -f "$LOG_FILE" "${LOG_FILE}.1" >/dev/null 2>&1 || true
    fi
  fi
}

rotate_log_if_needed

# =========================
# Logging
# =========================
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

on_error() {
  local exit_code=$?
  log_message "ERREUR: commande échouée (exit=$exit_code) à la ligne $1: $2"
  exit "$exit_code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# =========================
# Variables attendues (.env)
# =========================
: "${PG_STACK_NAME:?PG_STACK_NAME manquant dans .env}"
: "${KC_STACK_NAME:?KC_STACK_NAME manquant dans .env}"
: "${REDIS_STACK_NAME:?REDIS_STACK_NAME manquant dans .env}"
: "${TRAEFIK_STACK_NAME:?TRAEFIK_STACK_NAME manquant dans .env}"
: "${TRAEFIK_PORT_INTERNAL:?TRAEFIK_PORT_INTERNAL manquant dans .env}"

: "${TRAEFIK_YML:?Variable TRAEFIK_YML manquante dans le fichier config.env}"
: "${REDIS_YML:?Variable REDIS_YML manquante dans le fichier config.env}"
: "${POSTGRES_YML:?Variable POSTGRES_YML manquante dans le fichier config.env}"
: "${KEYCLOAK_YML:?Variable KEYCLOAK_YML manquante dans le fichier config.env}"

# =========================
# Helpers
# =========================
service_exists() {
  docker stack ls --format '{{.Name}}' | grep -Fxq "$1"
}

wait_docker_ready() {
  log_message "Vérification de l'état de Docker et Docker Swarm (timeout=${MAX_WAIT}s)..."

  local elapsed=0
  local swarm_state="unknown"

  while [ "$elapsed" -lt "$MAX_WAIT" ]; do
    # 1) Docker daemon disponible ?
    if docker info >/dev/null 2>&1; then
      # 2) État Swarm
      swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo unknown)"

      case "$swarm_state" in
        active)
          log_message "Docker et Swarm prêts après ${elapsed}s (state=active)"
          return 0
          ;;
        inactive)
          log_message "Docker prêt mais Swarm inactif (state=inactive) — attente..."
          ;;
        pending)
          log_message "Docker prêt mais Swarm en cours d'initialisation (state=pending) — attente..."
          ;;
        *)
          log_message "Docker prêt mais état Swarm inconnu ($swarm_state) — attente..."
          ;;
      esac
    else
      log_message "Docker pas encore prêt (${elapsed}s/${MAX_WAIT}s) — attente..."
    fi

    sleep "$WAIT_INTERVAL"
    elapsed=$((elapsed + WAIT_INTERVAL))
  done

  log_message "ERREUR: Docker/Swarm indisponible après ${MAX_WAIT}s (dernier état Swarm=$swarm_state)"
  return 1
}


check_swarm_active() {
  log_message "Vérification de l'état de Docker Swarm..."
  local swarm_status
  swarm_status="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"

  if [ "$swarm_status" != "active" ]; then
    log_message "ERREUR: Docker Swarm non actif (état: $swarm_status)"
    return 1
  fi
  log_message "Docker Swarm est actif"
  return 0
}

wait_service_replicas_stable() {
  local service="$1"
  local timeout="${2:-180}"
  local elapsed=0

  log_message "Attente stabilisation: $service (timeout=${timeout}s)"
  while [ "$elapsed" -lt "$timeout" ]; do
    local replicas
    replicas="$(docker service ls --filter "name=$service" --format "{{.Replicas}}" 2>/dev/null || true)"

    if [ -n "$replicas" ] && echo "$replicas" | grep -qE '^[0-9]+/[0-9]+$'; then
      local running="${replicas%/*}"
      local desired="${replicas#*/}"
      if [ "$desired" -gt 0 ] && [ "$running" -eq "$desired" ]; then
        log_message "Service stable: $service ($replicas)"
        return 0
      fi
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  log_message "ATTENTION: service $service non stable après ${timeout}s"
  return 1
}

force_update_service() {
  local service="$1"
  local stack_name
  stack_name="$(docker service ls --format '{{.Name}}' | grep -E "$service")"
  log_message "Force update: $stack_name"
  [[ -z "$stack_name" ]] && return 1

  if docker service update --force "$stack_name" >/dev/null 2>&1; then
    log_message "Force update OK: $stack_name"
    return 0
  fi
  log_message "ERREUR: échec du force update sur $stack_name"
  return 1
}

check_traefik_http() {
  if command -v curl >/dev/null 2>&1; then
    local code
    code="$(curl -s -o /dev/null -w "%{http_code}" "$TRAEFIK_LOCAL_URL" || true)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      log_message "Traefik répond sur ${TRAEFIK_PORT_INTERNAL} (HTTP $code)"
      return 0
    fi
    log_message "ATTENTION: Traefik ne répond pas sur ${TRAEFIK_PORT_INTERNAL} (HTTP=000)"
    return 1
  fi
  log_message "curl absent: test HTTP Traefik ignoré"
  return 0
}

# =========================
# Main
# =========================
log_message "=== Démarrage restart-docker-stacks ==="
log_message "Services ciblés:"
log_message "  Traefik              : $TRAEFIK_STACK_NAME"
log_message "  Redis                : $REDIS_STACK_NAME"
log_message "  PostgreSQL           : $PG_STACK_NAME"
log_message "  Keycloak             : $KC_STACK_NAME"
log_message "  ENV_FILES            : ${ENV_FILES[*]}"
log_message "  LOG_DIR              : $LOG_DIR"
log_message " LOG_FILE              : $LOG_FILE"

wait_docker_ready
check_swarm_active

log_message "Stabilisation système (15s)..."
sleep 15

# 1) Traefik
if service_exists "$TRAEFIK_STACK_NAME"; then
  if ! wait_service_replicas_stable "$TRAEFIK_STACK_NAME" 180; then
    force_update_service "$TRAEFIK_STACK_NAME" || true
    wait_service_replicas_stable "$TRAEFIK_STACK_NAME" 240 || true
  else
    log_message "Redis déjà stable: pas de redémarrage forcé."
  fi
else
  log_message "INFO: service Traefik absent ($TRAEFIK_STACK_NAME)."
fi

# 2) Redis
if service_exists "$REDIS_STACK_NAME"; then
  if ! wait_service_replicas_stable "$REDIS_STACK_NAME" 180; then
    force_update_service "$REDIS_STACK_NAME" || true
    wait_service_replicas_stable "$REDIS_STACK_NAME" 240 || true
  else
    log_message "Redis déjà stable: pas de redémarrage forcé."
  fi
else
  log_message "INFO: service Redis absent ($REDIS_STACK_NAME)."
fi

# 3) PostgreSQL
if service_exists "$PG_STACK_NAME"; then
  if ! wait_service_replicas_stable "$PG_STACK_NAME" 180; then
    force_update_service "$PG_STACK_NAME" || exit 1
    wait_service_replicas_stable "$PG_STACK_NAME" 240 || true
  else
    log_message "PostgreSQL déjà stable: pas de redémarrage forcé."
  fi
else
  log_message "ERREUR: service PostgreSQL absent ($PG_STACK_NAME)."
  exit 1
fi

# 4) Keycloak
if service_exists "$KC_STACK_NAME"; then
  if ! wait_service_replicas_stable "$KC_STACK_NAME" 180; then
    force_update_service "$KC_STACK_NAME" || exit 1
    wait_service_replicas_stable "$KC_STACK_NAME" 240 || true
  else
    log_message "Keycloak déjà stable: pas de redémarrage forcé."
  fi
else
  log_message "ERREUR: service Keycloak absent ($KC_STACK_NAME)."
  exit 1
fi

# Résumé
log_message "Vérification finale des replicas:"
log_message "Traefik:   $(docker service ls --filter name="$TRAEFIK_STACK_NAME" --format "{{.Replicas}}" 2>/dev/null || echo 'N/A')"
log_message "Redis:     $(docker service ls --filter name="$REDIS_STACK_NAME" --format "{{.Replicas}}" 2>/dev/null || echo 'N/A')"
log_message "PostgreSQL:$(docker service ls --filter name="$PG_STACK_NAME" --format "{{.Replicas}}" 2>/dev/null || echo 'N/A')"
log_message "Keycloak:  $(docker service ls --filter name="$KC_STACK_NAME" --format "{{.Replicas}}" 2>/dev/null || echo 'N/A')"

log_message "=== Script terminé ==="
exit 0
