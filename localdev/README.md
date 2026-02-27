# localdev — Kerberos + PostgreSQL local dev environment

Spins up a self-contained Kerberos (FreeIPA) + PostgreSQL environment in Docker
for testing JDBC Kerberos connectors locally (Trino Oracle / PostgreSQL connectors).

## Containers

Three containers are created under the configured domain (default `fed.devtest`):

| Container | IP | Role |
|---|---|---|
| `dns.<domain>` | 172.20.0.10 | dnsmasq — authoritative DNS for the domain |
| `freeipa.<domain>` | 172.20.0.11 | FreeIPA KDC + LDAP |
| `postgres.<domain>` | 172.20.0.12 | PostgreSQL 16 with GSS/Kerberos auth |

The Kerberos realm is derived automatically by uppercasing the domain
(e.g. `fed.devtest` → `FED.DEVTEST`, `corp.example` → `CORP.EXAMPLE`).

## Quick start

```bash
# Full setup with default domain fed.devtest (takes 5-15 min on first run)
IPA_PASSWORD=Admin1234! ./setup.sh

# Custom domain
IPA_PASSWORD=Admin1234! ./setup.sh --domain corp.example

# Reuse existing FreeIPA data volume, just recreate other containers
IPA_PASSWORD=Admin1234! ./setup.sh --skip-ipa
IPA_PASSWORD=Admin1234! ./setup.sh --domain corp.example --skip-ipa

# Check status
./status.sh
./status.sh --domain corp.example     # or: DOMAIN=corp.example ./status.sh

# Tear down (preserves FreeIPA data volume by default)
./teardown.sh
./teardown.sh --domain corp.example

# Tear down and wipe everything
./teardown.sh --clean-ipa-data --clean-outputs
```

## Outputs (generated, gitignored)

After `setup.sh` completes, `outputs/` contains:

| File | Purpose |
|---|---|
| `trino.keytab` / `trino.keytab.b64` | Trino client keytab |
| `postgres.keytab` / `postgres.keytab.b64` | PostgreSQL service keytab |
| `krb5.conf` | Kerberos client config — copy to `/etc/trino/krb5.conf` |
| `postgres.properties` | Ready-to-use Trino catalog config |

These files are listed in `outputs/.gitignore` and will never be committed.

The `dns/dnsmasq.conf` and `krb5.conf` files are also generated at setup time
from `*.tpl` templates and are gitignored — only the templates are committed.

## Trino integration

1. Copy `outputs/krb5.conf` to `/etc/trino/krb5.conf` on the Trino host
2. Copy `outputs/postgres.properties` to `/etc/trino/catalog/postgres.properties`
3. Ensure `-Djava.security.krb5.conf=/etc/trino/krb5.conf` is in `jvm.config`
4. Connect the Trino container to the `kdc-net` Docker network

## Principals created

- `postgres/postgres.<domain>@<REALM>` — service principal for PostgreSQL
- `trino@<REALM>` — client principal for Trino

Keytabs are restricted to `aes256-cts-hmac-sha1-96` (etype 18) for compatibility
with the Apache Kerby in-memory Kerberos client used by Trino's JDBC connectors.

## Notes

- FreeIPA data is persisted in `freeipa/data/` (volume-mounted). Use `--skip-ipa`
  on subsequent runs to avoid the 5-15 min install. The data directory is tied to
  the domain used during initial setup — changing the domain requires a full rebuild.
- `envsubst` (from `gettext`) is used to render templates. If unavailable, `sed`
  is used as a fallback. Install with `apt-get install gettext-base` or
  `brew install gettext`.
