[libdefaults]
  default_realm = ${REALM}
  dns_lookup_kdc = true
  dns_lookup_realm = false
  udp_preference_limit = 1
  permitted_enctypes = aes256-cts-hmac-sha384-192 aes128-cts-hmac-sha256-128 aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
  ${REALM} = {
    kdc = freeipa.${DOMAIN}
    admin_server = freeipa.${DOMAIN}
  }

[domain_realm]
  .${DOMAIN} = ${REALM}
  ${DOMAIN} = ${REALM}
