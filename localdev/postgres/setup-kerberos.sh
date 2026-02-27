#!/usr/bin/env bash
# Run inside the PostgreSQL container as the 'postgres' OS user.
# Configures Kerberos/GSS authentication and reloads config.
set -euo pipefail

REALM="${KRB_REALM:-FED.DEVTEST}"
PGDATA="${PGDATA:-/var/lib/postgresql/data}"

log() { echo "[pg-kerberos] $*"; }

# ── Sanity check ───────────────────────────────────────────────────────────
if [ ! -f /etc/postgresql/krb5.keytab ]; then
  echo "ERROR: /etc/postgresql/krb5.keytab not found. Copy it before running this script." >&2
  exit 1
fi

log "Keytab present: $(klist -k /etc/postgresql/krb5.keytab 2>&1 | head -5)"

# ── postgresql.conf: set keytab path ──────────────────────────────────────
log "Setting krb_server_keyfile..."
psql -v ON_ERROR_STOP=1 -c \
  "ALTER SYSTEM SET krb_server_keyfile = '/etc/postgresql/krb5.keytab';"

# ── pg_hba.conf: prepend GSS rule ─────────────────────────────────────────
# Prepend so GSS is tried before md5/scram for remote connections.
log "Adding GSS auth rule to pg_hba.conf..."
TMP=$(mktemp)
cat > "$TMP" << EOF
# ── Kerberos/GSS (added by setup-kerberos.sh) ─────────────────────────────
# include_realm=0 : strip '@FED.DEVTEST' so the login name matches the PG user
host    all     all     0.0.0.0/0     gss include_realm=0 krb_realm=${REALM}
EOF
cat "${PGDATA}/pg_hba.conf" >> "$TMP"
cp "$TMP" "${PGDATA}/pg_hba.conf"
rm "$TMP"

# ── Reload ────────────────────────────────────────────────────────────────
log "Reloading PostgreSQL configuration..."
psql -v ON_ERROR_STOP=1 -c "SELECT pg_reload_conf();"

log "Done. PostgreSQL now accepts Kerberos/GSS authentication."
