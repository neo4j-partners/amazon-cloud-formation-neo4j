configure_tls() {
  local advertisedDNS="$1"
  local loadBalancerDNSName="$2"
  local certsBase="${NEO4J_CERTS_DIR:-/var/lib/neo4j/certificates}"

  # Opt-out path (Public without TLS only — Private/ExistingVpc always pass a
  # non-empty AdvertisedDNS). Browser stays HTTP/7474, Bolt stays plaintext,
  # both advertised via the NLB DNS so in-VPC clients can still connect.
  if [[ -z "${advertisedDNS}" ]]; then
    echo "TLS disabled (no AdvertisedDNS); leaving Browser and Bolt plaintext."
    set_neo4j_conf server.default_advertised_address "${loadBalancerDNSName}"
    set_neo4j_conf server.bolt.advertised_address "${loadBalancerDNSName}:7687"
    set_neo4j_conf server.http.enabled true
    set_neo4j_conf server.http.listen_address 0.0.0.0:7474
    set_neo4j_conf server.http.advertised_address "${loadBalancerDNSName}:7474"
    set_neo4j_conf server.https.enabled false
    return 0
  fi

  echo "Configuring TLS for Bolt and HTTPS..."
  command -v openssl >/dev/null 2>&1 || dnf install -y openssl
  local _proto _dir _key _crt
  for _proto in bolt https; do
    _dir="${certsBase}/${_proto}"
    _key="${_dir}/private.key"
    _crt="${_dir}/public.crt"
    if [[ -f "${_key}" && -f "${_crt}" ]]; then
      echo "  Reusing existing self-signed cert in ${_dir}"
    else
      echo "  Generating self-signed cert in ${_dir}..."
      mkdir -p "${_dir}"
      umask 077
      openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${_key}" -out "${_crt}" -days 3650 \
        -subj "/CN=neo4j-${_proto}" >/dev/null 2>&1
      umask 022
    fi
    chown -R neo4j:neo4j "${_dir}"
    chmod 600 "${_key}"
    chmod 644 "${_crt}"
  done

  set_neo4j_conf server.default_advertised_address "${advertisedDNS}"
  set_neo4j_conf server.bolt.advertised_address "${advertisedDNS}:7687"
  set_neo4j_conf server.http.enabled false
  set_neo4j_conf server.https.enabled true
  set_neo4j_conf server.https.listen_address 0.0.0.0:7473
  set_neo4j_conf server.https.advertised_address "${advertisedDNS}:7473"
  set_neo4j_conf dbms.ssl.policy.bolt.enabled true
  set_neo4j_conf dbms.ssl.policy.bolt.base_directory "${certsBase}/bolt"
  set_neo4j_conf dbms.ssl.policy.bolt.private_key private.key
  set_neo4j_conf dbms.ssl.policy.bolt.public_certificate public.crt
  set_neo4j_conf dbms.ssl.policy.bolt.client_auth NONE
  set_neo4j_conf server.bolt.tls_level REQUIRED
  set_neo4j_conf dbms.ssl.policy.https.enabled true
  set_neo4j_conf dbms.ssl.policy.https.base_directory "${certsBase}/https"
  set_neo4j_conf dbms.ssl.policy.https.private_key private.key
  set_neo4j_conf dbms.ssl.policy.https.public_certificate public.crt
  set_neo4j_conf dbms.ssl.policy.https.client_auth NONE
}
