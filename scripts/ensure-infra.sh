#!/bin/bash
# Objectif:
# - Se placer à la racine du projet
# - Charger environments/homeLab/.env
# - Vérifier que Docker est prêt
# - Initialiser Swarm si nécessaire
# - Créer/valider les réseaux overlay requis (liste dans .env)
#
# Ce script NE déploie PAS les stacks et NE teste PAS la santé applicative.
# Il garantit uniquement les prérequis "infra".

set -euo pipefail

# ------------------------------------------------------------
# Placement : se positionner à la racine du projet, quel que soit le cwd
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# Paramètres (surcharge possible via config.env)
# ------------------------------------------------------------
MAX_WAIT="${MAX_WAIT:-420}"
WAIT_INTERVAL="${WAIT_INTERVAL:-10}"

# ------------------------------------------------------------
# Logging (serveur) : fichier + terminal
# ------------------------------------------------------------
LOG_DIR="${LOG_DIR:-/tmp}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/ensure-infra.log}"
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

# ------------------------------------------------------------
# Variables attendues
# ------------------------------------------------------------
: "${OVERLAY_NETWORKS:?OVERLAY_NETWORKS manquant dans config.env }"
: "${OVERLAY_ATTACHABLE:?OVERLAY_ATTACHABLE manquant dans config.env }"

# ------------------------------------------------------------
# Docker/Swarm helpers
# ------------------------------------------------------------
docker_ready() {
  docker info >/dev/null 2>&1
}

wait_docker_ready() {
  local elapsed=0

  log "Vérification Docker (timeout=${MAX_WAIT}s)..."
  while [ "$elapsed" -lt "$MAX_WAIT" ]; do
    if docker_ready; then
      log "Docker prêt après ${elapsed}s"
      return 0
    fi
    log "Docker pas encore prêt (${elapsed}s/${MAX_WAIT}s) -> attente..."
    sleep "$WAIT_INTERVAL"
    elapsed=$((elapsed + WAIT_INTERVAL))
  done
  return 1
}

swarm_active() {
  docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q '^active$'
}

init_swarm_if_needed() {
  if swarm_active; then
    log "Swarm déjà actif"
    return 0
  fi

  log "Swarm inactif -> initialisation"
  local local_ip
  local_ip="$(hostname -I | awk '{print $1}')"
  [ -n "$local_ip" ] || die "Impossible de déterminer l'IP locale (hostname -I)"

  docker swarm init --advertise-addr "$local_ip" >/dev/null
  log "Swarm initialisé (advertise-addr=$local_ip)"
}

net_exists() {
  docker network ls --format '{{.Name}}' | grep -q "^$1$"
}

net_is_overlay() {
  local net="$1"
  local driver
  driver="$(docker network inspect "$net" --format '{{.Driver}}' 2>/dev/null || true)"
  [ "$driver" = "overlay" ]
}

ensure_overlay_network() {
  local net="$1"

  if net_exists "$net"; then
    if net_is_overlay "$net"; then
      log "Réseau OK: $net (overlay)"
      return 0
    fi
    die "Le réseau '$net' existe mais n'est pas de type overlay. Action manuelle requise (suppression/renommage)."
  fi

  log "Création réseau overlay: $net (attachable=$OVERLAY_ATTACHABLE)"
  if [ "$OVERLAY_ATTACHABLE" = "true" ]; then
    docker network create --driver=overlay --attachable "$net" >/dev/null
  else
    docker network create --driver=overlay "$net" >/dev/null
  fi
  log "Réseau créé: $net"
}

# ------------------------------------------------------------
# Run
# ------------------------------------------------------------
log "=== ENSURE INFRA (Swarm + réseaux overlay) ==="
log "PROJECT_ROOT        : $PROJECT_ROOT"
log "CONF_FILE           : $CONF_FILE"
log "ENV_FILES           : ${ENV_FILES[*]}"
log "LOG_DIR             : $LOG_DIR"
log "LOG_FILE            : $LOG_FILE"
log "OVERLAY_NETWORKS    : $OVERLAY_NETWORKS"
log "OVERLAY_ATTACHABLE  : $OVERLAY_ATTACHABLE"
log "MAX_WAIT            : $MAX_WAIT"
log "WAIT_INTERVAL       : $WAIT_INTERVAL"

if ! wait_docker_ready; then
  die "Docker indisponible après attente. Vérifiez le paquet Docker DSM."
fi

init_swarm_if_needed

# OVERLAY_NETWORKS: "net1,net2,net3"
IFS=',' read -r -a NETS <<< "$OVERLAY_NETWORKS"

# Nettoyage des espaces éventuels
for i in "${!NETS[@]}"; do
  NETS[$i]="$(echo "${NETS[$i]}" | xargs)"
done

log "=== RÉSEAUX ==="
for net in "${NETS[@]}"; do
  [ -n "$net" ] || continue
  ensure_overlay_network "$net"
done

log "=== RÉSUMÉ (infra) ==="
log "Swarm state: $(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo 'unknown')"
log "Networks présents:"
for net in "${NETS[@]}"; do
  [ -n "$net" ] || continue
  if net_exists "$net"; then
    log "  - $net ($(docker network inspect "$net" --format 'Driver={{.Driver}} Scope={{.Scope}}' 2>/dev/null || echo 'inspect failed'))"
  else
    log "  - $net (ABSENT)"
  fi
done

log "OK: prérequis infra satisfaits."
exit 0
