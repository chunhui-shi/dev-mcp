#!/usr/bin/env bash
# Removes all containers, the Docker network, and optionally the FreeIPA data volume.
set -euo pipefail

DOMAIN="${DOMAIN:-fed.devtest}"
NETWORK="kdc-net"

log() { echo "$(date '+%H:%M:%S') ▶ $*"; }

KEEP_IPA_DATA=false
CLEAN_OUTPUTS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)        DOMAIN="$2"; shift 2 ;;
    --clean-ipa-data) KEEP_IPA_DATA=false; shift ;;
    --keep-ipa-data)  KEEP_IPA_DATA=true; shift ;;
    --clean-outputs)  CLEAN_OUTPUTS=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

for name in "postgres.${DOMAIN}" "freeipa.${DOMAIN}" "dns.${DOMAIN}"; do
  if docker inspect "$name" >/dev/null 2>&1; then
    log "Removing container: $name"
    docker rm -f "$name"
  fi
done

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  log "Removing network: $NETWORK"
  docker network rm "$NETWORK"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! $KEEP_IPA_DATA && [ -d "${SCRIPT_DIR}/freeipa/data" ]; then
  log "Removing FreeIPA data directory (use --keep-ipa-data to preserve)..."
  rm -rf "${SCRIPT_DIR}/freeipa/data"
fi

if $CLEAN_OUTPUTS && [ -d "${SCRIPT_DIR}/outputs" ]; then
  log "Removing outputs directory..."
  rm -rf "${SCRIPT_DIR}/outputs"
fi

log "Tear-down complete."
