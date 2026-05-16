apply_base_conf() {
  local base="${NEO4J_BASE_CONF:-/opt/neo4j/conf/neo4j-base.conf}"
  echo "Applying static base configuration..."
  # `|| [[ -n "${line}" ]]` processes a final line with no trailing newline.
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    if [[ "${line}" != *=* || "${line}" == =* ]]; then
      fail "Malformed line in neo4j-base.conf: '${line}'"
    fi
    set_neo4j_conf "${line%%=*}" "${line#*=}"
  done < "${base}"
}

assert_security_invariant() {
  local conf="${NEO4J_CONF:-/etc/neo4j/neo4j.conf}"
  local value
  value=$(awk -F= '/^internal\.dbms\.cypher_ip_blocklist=/ {sub(/^[^=]*=/, ""); print; exit}' "${conf}")
  if [[ -z "${value}" ]]; then
    fail "Security invariant missing: internal.dbms.cypher_ip_blocklist is absent or empty in ${conf}."
  fi
}

configure_network_advertised_addresses() {
  local loadBalancerDNSName="$1"
  local boltAdvertisedDNS="$2"
  echo "Configuring advertised addresses in neo4j.conf..."
  set_neo4j_conf server.default_advertised_address "${loadBalancerDNSName}"
  set_neo4j_conf server.bolt.advertised_address "${boltAdvertisedDNS:-${loadBalancerDNSName}}:7687"
  set_neo4j_conf server.http.advertised_address "${loadBalancerDNSName}:7474"
}

configure_memory_recommendation() {
  local conf="${NEO4J_CONF:-/etc/neo4j/neo4j.conf}"
  neo4j-admin server memory-recommendation >> "${conf}"
}

configure_cluster() {
  local nodeCount="$1"
  local region="$2"
  local _stack_id="$3"
  if [[ ${nodeCount} == 1 ]]; then
    echo "Running on a single node."
    return 0
  fi
  echo "Running on multiple nodes.  Configuring membership in neo4j.conf..."
  local -r privateIP="$(hostname -i | awk '{print $NF}')"
  set_neo4j_conf server.cluster.listen_address 0.0.0.0:6000
  set_neo4j_conf server.cluster.advertised_address "${privateIP}:6000"
  set_neo4j_conf server.cluster.raft.listen_address 0.0.0.0:7000
  set_neo4j_conf server.cluster.raft.advertised_address "${privateIP}:7000"
  set_neo4j_conf server.routing.listen_address 0.0.0.0:7688
  set_neo4j_conf server.routing.advertised_address "${privateIP}:7688"
  set_neo4j_conf initial.dbms.default_primaries_count 3
  set_neo4j_conf initial.dbms.default_secondaries_count "$(expr ${nodeCount} - 3)"
  set_neo4j_conf dbms.cluster.minimum_initial_system_primaries_count "${nodeCount}"
  coreMembers=""
  for attempt in $(seq 1 30); do
    asgNames=$(aws autoscaling describe-auto-scaling-groups --region "$region" --query "AutoScalingGroups[?Tags[?Key=='StackID' && Value=='${_stack_id}'] && Tags[?Key=='Role' && Value=='neo4j-cluster-node']].AutoScalingGroupName" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | grep -v '^None$' | xargs || true)
    if [[ -n "${asgNames}" ]]; then
      instanceIds=$(aws autoscaling describe-auto-scaling-groups --region "$region" --auto-scaling-group-names ${asgNames} --query "AutoScalingGroups[].Instances[].InstanceId" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | grep -v '^None$' | xargs || true)
      if [[ -n "${instanceIds}" ]]; then
        coreMembers=$(aws ec2 describe-instances --region "$region" --instance-ids ${instanceIds} --query "Reservations[].Instances[].PrivateIpAddress" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | grep -v '^None$' | awk '{print $1":6000"}' | paste -sd, - || true)
      fi
    fi
    foundCount=0
    [[ -n "${coreMembers}" ]] && foundCount=$(echo "${coreMembers}" | awk -F, '{print NF}')
    [[ ${foundCount} -ge ${nodeCount} ]] && break
    echo "Peer discovery attempt ${attempt}/30: found ${foundCount}/${nodeCount} members, retrying in 10s..."
    sleep 10
  done
  foundCount=0
  [[ -n "${coreMembers}" ]] && foundCount=$(echo "${coreMembers}" | awk -F, '{print NF}')
  if [[ -z "${coreMembers}" || ${foundCount} -lt ${nodeCount} ]]; then
    fail "Peer discovery failed after 5 minutes."
  fi
  echo "CoreMembers = ${coreMembers}"
  set_neo4j_conf dbms.cluster.discovery.resolver_type LIST
  set_neo4j_conf dbms.cluster.endpoints "${coreMembers}"
}

configure_bolt_tls() {
  local boltCertArn="$1"
  local region="$2"
  [[ -n "${boltCertArn}" ]] || return 0
  local neo4j_home="${NEO4J_HOME:-/var/lib/neo4j}"
  local cert_dir="${NEO4J_CERT_DIR:-${neo4j_home}/certificates/bolt}"
  mkdir -p "${cert_dir}"
  local _secret_json
  _secret_json=$(aws secretsmanager get-secret-value --region "${region}" \
    --secret-id "${boltCertArn}" --query SecretString --output text)
  if ! echo "${_secret_json}" | jq -e 'has("certificate") and has("private_key")' >/dev/null; then
    fail "Secret ${boltCertArn} must be JSON with fields 'certificate' (PEM) and 'private_key' (PEM)."
  fi
  umask 077
  echo "${_secret_json}" | jq -r '.private_key' > "${cert_dir}/private.key"
  echo "${_secret_json}" | jq -r '.certificate' > "${cert_dir}/public.crt"
  umask 022
  unset _secret_json
  chown -R neo4j:neo4j "$(dirname "${cert_dir}")"
  chmod 600 "${cert_dir}/private.key"
  chmod 644 "${cert_dir}/public.crt"
  set_neo4j_conf dbms.ssl.policy.bolt.enabled true
  set_neo4j_conf dbms.ssl.policy.bolt.base_directory "${cert_dir}"
  set_neo4j_conf dbms.ssl.policy.bolt.private_key private.key
  set_neo4j_conf dbms.ssl.policy.bolt.public_certificate public.crt
  set_neo4j_conf dbms.ssl.policy.bolt.client_auth NONE
  set_neo4j_conf server.bolt.tls_level REQUIRED
}

configure_plugin_settings() {
  local installBloom="$1"
  local bloomLicenseSecretArn="$2"
  local installGDS="$3"
  local gdsLicenseSecretArn="$4"
  local neo4j_home="${NEO4J_HOME:-/var/lib/neo4j}"
  echo "Configuring plugin settings in neo4j.conf..."
  if [[ "${installBloom}" == "true" ]]; then
    set_neo4j_conf server.unmanaged_extension_classes "com.neo4j.bloom.server=/bloom,semantics.extension=/rdf"
    if [[ -n "${bloomLicenseSecretArn}" ]]; then
      set_neo4j_conf dbms.bloom.license_file "${neo4j_home}/licenses/neo4j-bloom.license"
    fi
  fi
  if [[ "${installGDS}" == "true" && -n "${gdsLicenseSecretArn}" ]]; then
    set_neo4j_conf gds.enterprise.license_file "${neo4j_home}/licenses/neo4j-gds.license"
  fi
}

remove_jdwp_default() {
  local conf="${NEO4J_CONF:-/etc/neo4j/neo4j.conf}"
  sed -i.bak '/jdwp/d' "${conf}"
  rm -f "${conf}.bak"
}
