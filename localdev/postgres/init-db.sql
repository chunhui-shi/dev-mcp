-- Initialisation SQL — runs once when the PostgreSQL container is first created.
-- Creates the 'trino' database user that maps to Kerberos principal trino@FED.DEVTEST.
-- The GSS auth rule in pg_hba.conf (added by setup-kerberos.sh) strips the realm,
-- so 'trino@FED.DEVTEST' logs in as the local user 'trino'.

CREATE USER trino;

CREATE DATABASE testdb OWNER trino;

\connect testdb
CREATE SCHEMA IF NOT EXISTS test AUTHORIZATION trino;

\connect testdb trino
CREATE TABLE IF NOT EXISTS test.hello (
    id   serial PRIMARY KEY,
    msg  text NOT NULL DEFAULT 'hello from kerberos'
);
INSERT INTO test.hello (msg) VALUES ('kerberos auth works!');
