# ${DOMAIN} zone — served entirely by this container
# All queries for ${DOMAIN} are answered locally; everything else
# is forwarded to upstream resolvers.

no-resolv
log-queries

domain=${DOMAIN}
local=/${DOMAIN}/
expand-hosts

# ── A records ──────────────────────────────────────────────────────────────
address=/dns.${DOMAIN}/${DNS_IP}
address=/freeipa.${DOMAIN}/${IPA_IP}
address=/postgres.${DOMAIN}/${PG_IP}

# ── PTR records (reverse DNS — important for Kerberos) ────────────────────
ptr-record=${DNS_PTR}.in-addr.arpa.,dns.${DOMAIN}
ptr-record=${IPA_PTR}.in-addr.arpa.,freeipa.${DOMAIN}
ptr-record=${PG_PTR}.in-addr.arpa.,postgres.${DOMAIN}

# ── Kerberos SRV records (client auto-discovery) ──────────────────────────
srv-host=_kerberos._udp.${DOMAIN},freeipa.${DOMAIN},88,0,100
srv-host=_kerberos._tcp.${DOMAIN},freeipa.${DOMAIN},88,0,100
srv-host=_kerberos-master._udp.${DOMAIN},freeipa.${DOMAIN},88,0,100
srv-host=_kerberos-master._tcp.${DOMAIN},freeipa.${DOMAIN},88,0,100
srv-host=_kpasswd._udp.${DOMAIN},freeipa.${DOMAIN},464,0,100
srv-host=_kpasswd._tcp.${DOMAIN},freeipa.${DOMAIN},464,0,100
srv-host=_ldap._tcp.${DOMAIN},freeipa.${DOMAIN},389,0,100
srv-host=_kerberos-adm._tcp.${DOMAIN},freeipa.${DOMAIN},749,0,100

# ── TXT record: Kerberos realm for domain ─────────────────────────────────
txt-record=_kerberos.${DOMAIN},${REALM}

# ── Upstream forwarders for non-local queries ─────────────────────────────
server=8.8.8.8
server=8.8.4.4
