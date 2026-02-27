# localdev — Kerberos + PostgreSQL local dev environment

Spins up a self-contained Kerberos (FreeIPA) + PostgreSQL environment in Docker
for testing JDBC Kerberos connectors locally (Trino Oracle / PostgreSQL connectors).

## Containers

| Container | IP | Role |
|---|---|---|
| `dns.fed.devtest` | 172.20.0.10 | dnsmasq — authoritative DNS for `fed.devtest` |
| `freeipa.fed.devtest` | 172.20.0.11 | FreeIPA KDC + LDAP |
| `postgres.fed.devtest` | 172.20.0.12 | PostgreSQL 16 with GSS/Kerberos auth |

## Quick start

```bash
# Full setup (takes 5-15 min on first run — FreeIPA install)
IPA_PASSWORD=Admin1234! ./setup.sh

# Reuse existing FreeIPA data volume, just recreate other containers
IPA_PASSWORD=Admin1234! ./setup.sh --skip-ipa

# Check status
./status.sh

# Tear down (preserves FreeIPA data volume by default)
./teardown.sh

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

## Trino integration

1. Copy `outputs/krb5.conf` to `/etc/trino/krb5.conf` on the Trino host
2. Copy `outputs/postgres.properties` to `/etc/trino/catalog/postgres.properties`
3. Ensure `-Djava.security.krb5.conf=/etc/trino/krb5.conf` is in `jvm.config`
4. Connect the Trino container to the `kdc-net` Docker network

## Principals created

- `postgres/postgres.fed.devtest@FED.DEVTEST` — service principal for PostgreSQL
- `trino@FED.DEVTEST` — client principal for Trino

Keytabs are restricted to `aes256-cts-hmac-sha1-96` (etype 18) for compatibility
with the Apache Kerby in-memory Kerberos client used by Trino's JDBC connectors.

## Notes

- FreeIPA data is persisted in `freeipa/data/` (volume-mounted). Use `--skip-ipa`
  on subsequent runs to avoid the 5-15 min install.
- The `outputs/` directory is gitignored to prevent accidental keytab commits.
- Realm: `FED.DEVTEST`, domain: `fed.devtest`
