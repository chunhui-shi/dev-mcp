#!/usr/bin/env bash
# Run inside the FreeIPA container after ipa-server-install completes.
# Creates:
#   - postgres/postgres.fed.devtest@FED.DEVTEST  (service principal for PostgreSQL)
#   - trino@FED.DEVTEST                          (user principal for Trino client)
# Writes keytabs to /root/{postgres,trino}.keytab
set -euo pipefail

REALM="FED.DEVTEST"
DOMAIN="fed.devtest"
PG_IP="${PG_IP:-172.20.0.12}"
IPA_HOST="freeipa.${DOMAIN}"
ADMIN_PASSWORD="${IPA_PASSWORD:?IPA_PASSWORD env var must be set}"

log() { echo "[principals] $*"; }

# ── Authenticate as admin ──────────────────────────────────────────────────
log "kinit admin..."
printf '%s' "$ADMIN_PASSWORD" | kinit admin

# ── PostgreSQL host entry (required before service-add) ────────────────────
log "Adding host: postgres.${DOMAIN}..."
ipa host-add "postgres.${DOMAIN}" --ip-address="$PG_IP" --no-reverse 2>/dev/null \
  || log "  (host already exists, continuing)"

# ── PostgreSQL service principal ───────────────────────────────────────────
log "Creating service principal: postgres/postgres.${DOMAIN}..."
ipa service-add "postgres/postgres.${DOMAIN}" 2>/dev/null \
  || log "  (service already exists, continuing)"

log "Extracting postgres service keytab..."
rm -f /root/postgres.keytab
ipa-getkeytab \
  -s "$IPA_HOST" \
  -p "postgres/postgres.${DOMAIN}@${REALM}" \
  -k /root/postgres.keytab \
  -e aes256-cts-hmac-sha1-96

# ── Trino client principal ─────────────────────────────────────────────────
log "Creating user principal: trino..."
ipa user-add trino \
  --first=Trino \
  --last=Client \
  --random \
  2>/dev/null || log "  (user already exists, continuing)"

# Set password expiry to far future so keytab-based kinit always works
log "Setting trino password expiry to 2099..."
ipa user-mod trino --setattr="krbPasswordExpiration=20991231235959Z" 2>/dev/null || true

log "Extracting trino client keytab..."
# Remove any existing keytab first — ipa-getkeytab appends to existing files,
# which would accumulate multiple KVNOs across re-runs of this script.
rm -f /root/trino.keytab
ipa-getkeytab \
  -s "$IPA_HOST" \
  -p "trino@${REALM}" \
  -k /root/trino.keytab \
  -e aes256-cts-hmac-sha1-96

log "Keytabs written to /root/postgres.keytab and /root/trino.keytab"
log "Verifying keytabs..."
klist -k -e /root/postgres.keytab | head -6
klist -k -e /root/trino.keytab    | head -6

kdestroy -A 2>/dev/null || true
log "Done."
