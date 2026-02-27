#!/usr/bin/env bash
# ============================================================
# setup.sh — Bootstrap a local Kerberos + PostgreSQL environment
#
# Containers created:
#   dns.<domain>      172.20.0.10  dnsmasq (authoritative DNS)
#   freeipa.<domain>  172.20.0.11  FreeIPA KDC + LDAP
#   postgres.<domain> 172.20.0.12  PostgreSQL 16 with GSS/Kerberos auth
#
# Output (in ./outputs/):
#   postgres.keytab / postgres.keytab.b64   — PostgreSQL service keytab
#   trino.keytab    / trino.keytab.b64      — Trino client keytab
#   krb5.conf                               — Kerberos client config
#   postgres.properties                     — Ready-to-use Trino catalog config
#
# Usage:
#   ./setup.sh                           # full setup (domain: fed.devtest)
#   ./setup.sh --domain my.realm         # custom domain
#   ./setup.sh --skip-ipa                # reuse existing FreeIPA data volume
#   ./setup.sh --domain my.realm --skip-ipa
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ───────────────────────────────────────────────────────
DOMAIN="fed.devtest"
SKIP_IPA=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)    DOMAIN="$2"; shift 2 ;;
    --skip-ipa)  SKIP_IPA=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Derive realm from domain (uppercase)
REALM=$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')

# ── Configuration ─────────────────────────────────────────────────────────
NETWORK="kdc-net"
SUBNET="172.20.0.0/16"

DNS_IP="172.20.0.10"
IPA_IP="172.20.0.11"
PG_IP="172.20.0.12"

DNS_NAME="dns.${DOMAIN}"
IPA_NAME="freeipa.${DOMAIN}"
PG_NAME="postgres.${DOMAIN}"

IPA_PASSWORD="${IPA_PASSWORD:-Admin1234!}"
PG_SUPERPASS="${PG_SUPERPASS:-postgres}"
OUTPUTS="${SCRIPT_DIR}/outputs"

mkdir -p "$OUTPUTS"

# ── Helpers ───────────────────────────────────────────────────────────────
log()  { echo "$(date '+%H:%M:%S') ▶ $*"; }
fail() { echo "$(date '+%H:%M:%S') ✖ $*" >&2; exit 1; }

# Reverse an IPv4 address for PTR records: 172.20.0.10 → 10.0.20.172
reverse_ip() { echo "$1" | awk -F. '{print $4"."$3"."$2"."$1}'; }

wait_ready() {
  local name=$1 cmd=$2 attempts=${3:-60} interval=${4:-10}
  log "Waiting for $name (up to $((attempts * interval))s)..."
  for i in $(seq 1 "$attempts"); do
    if docker exec "$name" sh -c "$cmd" >/dev/null 2>&1; then
      log "$name is ready."
      return 0
    fi
    echo "  ... attempt $i/$attempts"
    sleep "$interval"
  done
  log "Timeout waiting for $name. Recent logs:"
  docker logs --tail=40 "$name" >&2
  fail "$name did not become ready in time."
}

remove_if_exists() {
  if docker inspect "$1" >/dev/null 2>&1; then
    log "Removing existing container: $1"
    docker rm -f "$1"
  fi
}

# Generate a file from a .tpl template by substituting shell variables.
# Uses envsubst when available, falls back to sed.
render_template() {
  local tpl=$1 out=$2
  if command -v envsubst >/dev/null 2>&1; then
    envsubst < "$tpl" > "$out"
  else
    sed \
      -e "s|\${DOMAIN}|${DOMAIN}|g" \
      -e "s|\${REALM}|${REALM}|g"   \
      -e "s|\${DNS_IP}|${DNS_IP}|g" \
      -e "s|\${IPA_IP}|${IPA_IP}|g" \
      -e "s|\${PG_IP}|${PG_IP}|g"   \
      -e "s|\${DNS_PTR}|${DNS_PTR}|g" \
      -e "s|\${IPA_PTR}|${IPA_PTR}|g" \
      -e "s|\${PG_PTR}|${PG_PTR}|g"   \
      "$tpl" > "$out"
  fi
}

# ── Detect cgroup version (affects FreeIPA / systemd containers) ──────────
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  log "Detected cgroup v2"
  CGROUP_OPTS="--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw"
else
  log "Detected cgroup v1"
  CGROUP_OPTS="-v /sys/fs/cgroup:/sys/fs/cgroup:ro"
fi

# ── Generate config files from templates ──────────────────────────────────
log "Domain: ${DOMAIN}  Realm: ${REALM}"

DNS_PTR=$(reverse_ip "$DNS_IP")
IPA_PTR=$(reverse_ip "$IPA_IP")
PG_PTR=$(reverse_ip "$PG_IP")

export DOMAIN REALM DNS_IP IPA_IP PG_IP DNS_PTR IPA_PTR PG_PTR

log "Generating dns/dnsmasq.conf from template..."
render_template "${SCRIPT_DIR}/dns/dnsmasq.conf.tpl" "${SCRIPT_DIR}/dns/dnsmasq.conf"

log "Generating krb5.conf from template..."
render_template "${SCRIPT_DIR}/krb5.conf.tpl" "${SCRIPT_DIR}/krb5.conf"

# ═══════════════════════════════════════════════════════════════════════════
# Step 1 — Docker network
# ═══════════════════════════════════════════════════════════════════════════
log "=== Step 1: Docker network ==="
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  log "Network $NETWORK already exists."
else
  docker network create --subnet "$SUBNET" "$NETWORK"
  log "Created network $NETWORK ($SUBNET)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Step 2 — DNS container
# ═══════════════════════════════════════════════════════════════════════════
log "=== Step 2: DNS container ($DNS_NAME) ==="
remove_if_exists "$DNS_NAME"

# dnsmasq.conf was generated above from the template; bake it into the image
docker build -t kdc-dns "${SCRIPT_DIR}/dns/" -q

docker run -d \
  --name "$DNS_NAME" \
  --hostname "$DNS_NAME" \
  --network "$NETWORK" \
  --ip "$DNS_IP" \
  --cap-add NET_ADMIN \
  --cap-add NET_BIND_SERVICE \
  kdc-dns

wait_ready "$DNS_NAME" "pgrep dnsmasq" 12 5

# ═══════════════════════════════════════════════════════════════════════════
# Step 3 — FreeIPA container
# ═══════════════════════════════════════════════════════════════════════════
log "=== Step 3: FreeIPA KDC ($IPA_NAME) ==="

if $SKIP_IPA && docker inspect "$IPA_NAME" >/dev/null 2>&1; then
  log "--skip-ipa: reusing existing container"
else
  remove_if_exists "$IPA_NAME"
  mkdir -p "${SCRIPT_DIR}/freeipa/data"

  docker run -d \
    --name "$IPA_NAME" \
    --hostname "$IPA_NAME" \
    --network "$NETWORK" \
    --ip "$IPA_IP" \
    --dns "$DNS_IP" \
    $CGROUP_OPTS \
    --tmpfs /run:rw \
    --tmpfs /tmp:rw \
    --privileged \
    --sysctl net.ipv6.conf.lo.disable_ipv6=0 \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --security-opt seccomp=unconfined \
    -v /dev/urandom:/dev/random:ro \
    -v "${SCRIPT_DIR}/freeipa/data:/data:Z" \
    -e PASSWORD="$IPA_PASSWORD" \
    quay.io/freeipa/freeipa-server:fedora-41-4.12.5 \
    ipa-server-install -U \
      --realm="$REALM" \
      --domain="$DOMAIN" \
      --hostname="$IPA_NAME" \
      --no-ntp \
      --no-host-dns

  log "FreeIPA setup started — this takes 5–15 minutes on first run."
  # Wait for systemd to settle before checking ipactl
  sleep 30
fi

wait_ready "$IPA_NAME" "ipactl status 2>&1 | grep -q 'RUNNING'" 90 10

# ═══════════════════════════════════════════════════════════════════════════
# Step 4 — Create Kerberos principals and extract keytabs
# ═══════════════════════════════════════════════════════════════════════════
log "=== Step 4: Kerberos principals and keytabs ==="

# /tmp is a tmpfs inside the FreeIPA container; write keytabs to /root instead
docker exec \
  -e IPA_PASSWORD="$IPA_PASSWORD" \
  -e PG_IP="$PG_IP" \
  -e DOMAIN="$DOMAIN" \
  -e REALM="$REALM" \
  "$IPA_NAME" \
  bash -s < "${SCRIPT_DIR}/freeipa/setup-principals.sh"

# Fetch keytabs from the container
docker cp "$IPA_NAME":/root/postgres.keytab "${OUTPUTS}/postgres.keytab"
docker cp "$IPA_NAME":/root/trino.keytab    "${OUTPUTS}/trino.keytab"
log "Keytabs saved to ${OUTPUTS}/"

# Base64-encode for use in Trino connector properties
base64 < "${OUTPUTS}/postgres.keytab" | tr -d '\n' > "${OUTPUTS}/postgres.keytab.b64"
base64 < "${OUTPUTS}/trino.keytab"    | tr -d '\n' > "${OUTPUTS}/trino.keytab.b64"
log "Base64 keytabs: ${OUTPUTS}/*.keytab.b64"

# ═══════════════════════════════════════════════════════════════════════════
# Step 5 — PostgreSQL container
# ═══════════════════════════════════════════════════════════════════════════
log "=== Step 5: PostgreSQL ($PG_NAME) ==="
remove_if_exists "$PG_NAME"

# Note: do NOT set POSTGRES_DB here; init-db.sql creates testdb owned by trino.
docker run -d \
  --name "$PG_NAME" \
  --hostname "$PG_NAME" \
  --network "$NETWORK" \
  --ip "$PG_IP" \
  --dns "$DNS_IP" \
  -e POSTGRES_PASSWORD="$PG_SUPERPASS" \
  -v "${SCRIPT_DIR}/postgres/init-db.sql:/docker-entrypoint-initdb.d/01-init.sql:ro" \
  postgres:16

wait_ready "$PG_NAME" "pg_isready -U postgres" 30 5

# ═══════════════════════════════════════════════════════════════════════════
# Step 6 — Configure PostgreSQL Kerberos
# ═══════════════════════════════════════════════════════════════════════════
log "=== Step 6: Configure PostgreSQL Kerberos auth ==="

# Install krb5 client tools (for klist diagnostics)
docker exec "$PG_NAME" bash -c \
  "apt-get update -qq && apt-get install -y -qq krb5-user 2>&1 | tail -3"

# Drop the service keytab
docker cp "${OUTPUTS}/postgres.keytab" "$PG_NAME":/etc/postgresql/krb5.keytab
docker exec "$PG_NAME" bash -c \
  "chown postgres:postgres /etc/postgresql/krb5.keytab && chmod 600 /etc/postgresql/krb5.keytab"

# Drop krb5.conf (generated from template) so the container can use Kerberos tools
docker cp "${SCRIPT_DIR}/krb5.conf" "$PG_NAME":/etc/krb5.conf

# Configure postgresql.conf + pg_hba.conf and reload
docker exec -u postgres -e KRB_REALM="$REALM" "$PG_NAME" bash -s \
  < "${SCRIPT_DIR}/postgres/setup-kerberos.sh"

# ═══════════════════════════════════════════════════════════════════════════
# Step 7 — Write host /etc/hosts entries and output config
# ═══════════════════════════════════════════════════════════════════════════
log "=== Step 7: Host configuration ==="

# Write /etc/hosts suggestions (requires sudo — print them if we can't write)
HOSTS_LINES=(
  "${DNS_IP} ${DNS_NAME}"
  "${IPA_IP} ${IPA_NAME}"
  "${PG_IP}  ${PG_NAME}"
)
NEED_HOSTS=false
for line in "${HOSTS_LINES[@]}"; do
  host=$(echo "$line" | awk '{print $2}')
  grep -qF "$host" /etc/hosts 2>/dev/null || NEED_HOSTS=true
done

if $NEED_HOSTS; then
  if [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
    for line in "${HOSTS_LINES[@]}"; do
      host=$(echo "$line" | awk '{print $2}')
      grep -qF "$host" /etc/hosts || echo "$line" | sudo tee -a /etc/hosts >/dev/null
    done
    log "Added /etc/hosts entries for the containers."
  else
    log "⚠  Could not update /etc/hosts automatically. Add these lines manually:"
    for line in "${HOSTS_LINES[@]}"; do echo "      $line"; done
  fi
fi

# Copy generated krb5.conf to outputs for distribution
cp "${SCRIPT_DIR}/krb5.conf" "${OUTPUTS}/krb5.conf"

# Write Trino catalog config
TRINO_KEYTAB_B64=$(cat "${OUTPUTS}/trino.keytab.b64")
cat > "${OUTPUTS}/postgres.properties" << EOF
connector.name=postgresql
connection-url=jdbc:postgresql://${PG_NAME}:5432/testdb
postgresql.authentication.type=KERBEROS
kerberos.client.principal=trino@${REALM}
kerberos.client.keytab-base64=${TRINO_KEYTAB_B64}
EOF

# ═══════════════════════════════════════════════════════════════════════════
log ""
log "══════════════════════════════════════════════════════"
log " Setup complete!"
log "══════════════════════════════════════════════════════"
log " Containers:"
log "   ${DNS_NAME}      ${DNS_IP}  (dnsmasq)"
log "   ${IPA_NAME}  ${IPA_IP}  (KDC, admin: admin / ${IPA_PASSWORD})"
log "   ${PG_NAME} ${PG_IP}   (PostgreSQL, user: postgres / ${PG_SUPERPASS})"
log ""
log " Outputs in ${OUTPUTS}/:"
log "   postgres.keytab.b64  — service keytab (PostgreSQL)"
log "   trino.keytab.b64     — client keytab (Trino)"
log "   krb5.conf            — copy to /etc/trino/krb5.conf on the Trino host"
log "   postgres.properties  — Trino catalog config (needs postgresql connector"
log "                          with Kerberos support wired in)"
log ""
log " Quick smoke test:"
log "   docker exec ${PG_NAME} bash -c \\"
log "     'kinit -kt /tmp/trino.keytab trino@${REALM} && \\"
log "      psql -h ${PG_NAME} -U trino -d testdb -c \"SELECT * FROM test.hello;\"'"
log ""
log " To tear down: ./teardown.sh"
