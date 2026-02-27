#!/usr/bin/env bash
# Quick status check for all three containers.
set -euo pipefail

DOMAIN="fed.devtest"

ok()   { echo "  ✔ $*"; }
fail() { echo "  ✖ $*"; }
head() { echo; echo "── $* ──────────────────────────────────"; }

check_container() {
  local name=$1
  if docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null | grep -q running; then
    ok "$name is running"
    return 0
  else
    fail "$name is NOT running"
    return 1
  fi
}

head "Containers"
check_container "dns.${DOMAIN}"      || true
check_container "freeipa.${DOMAIN}"  || true
check_container "postgres.${DOMAIN}" || true

head "DNS resolution (from freeipa container)"
for host in "freeipa.${DOMAIN}" "postgres.${DOMAIN}" "dns.${DOMAIN}"; do
  if docker exec "freeipa.${DOMAIN}" getent hosts "$host" >/dev/null 2>&1; then
    ip=$(docker exec "freeipa.${DOMAIN}" getent hosts "$host" | awk '{print $1}')
    ok "$host → $ip"
  else
    fail "$host not resolvable"
  fi
done 2>/dev/null || true

head "FreeIPA services"
docker exec "freeipa.${DOMAIN}" ipactl status 2>&1 \
  | grep -Ei "RUNNING|stopped|FAILED" \
  | while read -r line; do
      echo "  $line"
    done || fail "Could not contact FreeIPA"

head "Kerberos (kinit test inside FreeIPA)"
docker exec -e IPA_PASSWORD="${IPA_PASSWORD:-Admin1234!}" \
  "freeipa.${DOMAIN}" \
  bash -c 'echo "$IPA_PASSWORD" | kinit admin >/dev/null 2>&1 && klist && kdestroy -A' \
  2>&1 | sed 's/^/  /' || fail "kinit admin failed"

head "PostgreSQL"
if docker exec "postgres.${DOMAIN}" pg_isready -U postgres >/dev/null 2>&1; then
  ok "PostgreSQL is accepting connections"
  docker exec "postgres.${DOMAIN}" psql -U postgres -c \
    "SELECT datname FROM pg_database WHERE datname NOT IN ('template0','template1');" \
    2>/dev/null | sed 's/^/  /' || true
else
  fail "PostgreSQL is not ready"
fi

echo
