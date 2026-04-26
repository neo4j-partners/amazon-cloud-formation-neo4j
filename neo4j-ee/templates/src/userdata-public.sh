export IS_FIRST_BOOT=false

_token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
_instance_id=$(curl -s -H "X-aws-ec2-metadata-token: $_token" http://169.254.169.254/latest/meta-data/instance-id)
logicalId=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=${_instance_id}" "Name=key,Values=aws:cloudformation:logical-id" --query "Tags[0].Value" --output text 2>/dev/null || true)
trap 'if [[ -n "${logicalId:-}" ]]; then cfn-signal --success false --stack "$stackName" --resource "$logicalId" --region "$region"; fi' ERR

set_neo4j_conf() {
  local conf=/etc/neo4j/neo4j.conf
  sed -i "s|^#\?$1=.*|$1=$2|" "$conf"
  if ! grep -q "^$1=" "$conf"; then
    echo "$1=$2" >> "$conf"
  fi
}

pin_neo4j_user() {
  getent group neo4j >/dev/null || groupadd -g 500 neo4j
  getent passwd neo4j >/dev/null || useradd -u 500 -g 500 -r -s /sbin/nologin -d /var/lib/neo4j neo4j
}

attach_and_mount_data_volume() {
  echo "Attaching and mounting data volume..."
  local _token
  _token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  local _instance_id
  _instance_id=$(curl -s -H "X-aws-ec2-metadata-token: $_token" http://169.254.169.254/latest/meta-data/instance-id)
  local _az
  _az=$(curl -s -H "X-aws-ec2-metadata-token: $_token" http://169.254.169.254/latest/meta-data/placement/availability-zone)
  if [[ -z "${_instance_id}" || -z "${_az}" ]]; then
    echo "ERROR: Could not read instance metadata from IMDSv2. Exiting."
    exit 1
  fi
  local _stack_id
  _stack_id=$(aws ec2 describe-tags --region "$region" \
    --filters "Name=resource-id,Values=${_instance_id}" \
              "Name=key,Values=aws:cloudformation:stack-id" \
    --query "Tags[0].Value" --output text)
  if [[ -z "${_stack_id}" || "${_stack_id}" == "None" ]]; then
    echo "ERROR: Could not read aws:cloudformation:stack-id tag. Exiting."
    exit 1
  fi
  local _vols _vol_count _data_vol_id
  _vols=$(aws ec2 describe-volumes --region "$region" \
    --filters "Name=tag:StackID,Values=${_stack_id}" \
              "Name=tag:Role,Values=neo4j-cluster-data" \
              "Name=availability-zone,Values=${_az}" \
    --query "Volumes[*].VolumeId" --output text)
  _vol_count=$(echo "${_vols}" | wc -w | xargs)
  if [[ "${_vol_count}" -ne 1 ]]; then
    echo "ERROR: Expected 1 data volume in AZ ${_az}, found ${_vol_count}. Exiting."
    exit 1
  fi
  _data_vol_id="${_vols}"
  echo "Data volume: ${_data_vol_id} in ${_az}"
  echo "  Waiting for volume ${_data_vol_id} to reach 'available' state (up to 10 min)..."
  local _vol_top_state _wait_s=0
  while true; do
    _vol_top_state=$(aws ec2 describe-volumes --region "$region" \
      --volume-ids "${_data_vol_id}" \
      --query "Volumes[0].State" --output text 2>/dev/null || echo "unknown")
    [[ "${_vol_top_state}" == "available" ]] && break
    if (( _wait_s >= 600 )); then
      echo "ERROR: Volume ${_data_vol_id} did not become available after 10 min (state=${_vol_top_state}). Exiting."
      exit 1
    fi
    echo "  Volume state: ${_vol_top_state}, waiting 10s... (${_wait_s}s elapsed)"
    sleep 10
    _wait_s=$(( _wait_s + 10 ))
  done
  local _attach_ok=false
  for _attach_try in $(seq 1 3); do
    if aws ec2 attach-volume --region "$region" \
        --volume-id "${_data_vol_id}" \
        --instance-id "${_instance_id}" \
        --device /dev/sdf >/dev/null 2>&1; then
      _attach_ok=true
      break
    fi
    echo "  attach-volume attempt ${_attach_try}/3 failed, retrying in 5s..."
    sleep 5
  done
  if [[ "${_attach_ok}" != "true" ]]; then
    echo "ERROR: Could not attach volume ${_data_vol_id} to ${_instance_id}. Exiting."
    exit 1
  fi
  echo "Waiting for volume ${_data_vol_id} to reach 'attached' state (up to 2 min)..."
  local _vol_state=""
  for _i in $(seq 1 24); do
    _vol_state=$(aws ec2 describe-volumes --region "$region" \
      --volume-ids "${_data_vol_id}" \
      --query "Volumes[0].Attachments[0].State" --output text 2>/dev/null || true)
    [[ "${_vol_state}" == "attached" ]] && break
    echo "  volume state: ${_vol_state} (${_i}/24)..."
    sleep 5
  done
  if [[ "${_vol_state}" != "attached" ]]; then
    echo "ERROR: Volume ${_data_vol_id} did not reach 'attached' within 2 minutes. Exiting."
    exit 1
  fi
  local _vol_serial="${_data_vol_id//-/}"
  local _data_dev=""
  for _nvme_try in $(seq 1 6); do
    for _dev in /dev/nvme*n1; do
      [[ -b "$_dev" ]] || continue
      if /sbin/ebsnvme-id -u "$_dev" 2>/dev/null | grep -q "${_data_vol_id}"; then
        _data_dev="$_dev"
        break 2
      fi
    done
    if [[ -L /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${_vol_serial} ]]; then
      _data_dev=$(readlink -f /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${_vol_serial})
      break
    fi
    sleep 2
  done
  if [[ -z "${_data_dev}" || ! -b "${_data_dev}" ]]; then
    echo "ERROR: Could not resolve NVMe device for volume ${_data_vol_id} after retries. Exiting."
    exit 1
  fi
  echo "NVMe device: ${_data_dev}"
  if ! blkid "${_data_dev}" > /dev/null 2>&1; then
    echo "First boot: formatting ${_data_dev} with xfs..."
    mkfs.xfs "${_data_dev}"
    IS_FIRST_BOOT=true
  fi
  local _uuid
  _uuid=$(blkid -s UUID -o value "${_data_dev}")
  if [[ -z "${_uuid}" ]]; then
    echo "ERROR: Could not read UUID from ${_data_dev}. Exiting."
    exit 1
  fi
  mkdir -p /var/lib/neo4j/data
  echo "UUID=${_uuid}  /var/lib/neo4j/data  xfs  defaults,nofail,noatime,x-systemd.device-timeout=30  0 2" >> /etc/fstab
  mount /var/lib/neo4j/data
  echo "Data volume mounted at /var/lib/neo4j/data"
  if [[ "${IS_FIRST_BOOT}" == "true" ]]; then
    chown neo4j:neo4j /var/lib/neo4j/data
  fi
}

install_neo4j_from_yum() {
  echo "Installing Graph Database..."
  rpm --import https://debian.neo4j.com/neotechnology.gpg.key
  echo "[neo4j]
name=Neo4j RPM Repository
baseurl=https://yum.neo4j.com/stable/latest
enabled=1
gpgcheck=1
" > /etc/yum.repos.d/neo4j.repo
  export NEO4J_ACCEPT_LICENSE_AGREEMENT=yes
  yum -y install neo4j-enterprise
  systemctl enable neo4j
}
extension_config() {
  echo Configuring extensions and security in neo4j.conf...
  set_neo4j_conf server.unmanaged_extension_classes "com.neo4j.bloom.server=/bloom,semantics.extension=/rdf"
  set_neo4j_conf dbms.security.procedures.unrestricted "gds.*,apoc.*,bloom.*"
  set_neo4j_conf dbms.security.http_auth_allowlist "/,/browser.*,/bloom.*"
  set_neo4j_conf dbms.security.procedures.allowlist "apoc.*,gds.*,bloom.*"
  sed -i '/jdwp/d' /etc/neo4j/neo4j.conf
}
build_neo4j_conf_file() {
  local -r privateIP="$(hostname -i | awk '{print $NF}')"
  echo "Configuring network in neo4j.conf..."
  set_neo4j_conf server.default_listen_address 0.0.0.0
  set_neo4j_conf server.default_advertised_address "${loadBalancerDNSName}"
  set_neo4j_conf server.bolt.listen_address 0.0.0.0:7687
  set_neo4j_conf server.bolt.advertised_address "${boltAdvertisedDNS:-${loadBalancerDNSName}}:7687"
  set_neo4j_conf server.http.listen_address 0.0.0.0:7474
  set_neo4j_conf server.http.advertised_address "${loadBalancerDNSName}:7474"
  neo4j-admin server memory-recommendation >> /etc/neo4j/neo4j.conf
  set_neo4j_conf server.metrics.enabled true
  set_neo4j_conf server.metrics.jmx.enabled true
  set_neo4j_conf server.metrics.prefix neo4j
  set_neo4j_conf server.metrics.filter "*"
  set_neo4j_conf server.metrics.csv.interval 5s
  set_neo4j_conf dbms.routing.default_router SERVER
  if [[ ${nodeCount} == 1 ]]; then
    echo "Running on a single node."
  else
    echo "Running on multiple nodes.  Configuring membership in neo4j.conf..."
    set_neo4j_conf server.cluster.listen_address 0.0.0.0:6000
    set_neo4j_conf server.cluster.advertised_address "${privateIP}:6000"
    set_neo4j_conf server.cluster.raft.listen_address 0.0.0.0:7000
    set_neo4j_conf server.cluster.raft.advertised_address "${privateIP}:7000"
    set_neo4j_conf server.routing.listen_address 0.0.0.0:7688
    set_neo4j_conf server.routing.advertised_address "${privateIP}:7688"
    set_neo4j_conf initial.dbms.default_primaries_count 3
    set_neo4j_conf initial.dbms.default_secondaries_count "$(expr ${nodeCount} - 3)"
    set_neo4j_conf dbms.cluster.minimum_initial_system_primaries_count "${nodeCount}"
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    instanceId=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
    if [[ -z "${instanceId}" ]]; then
      echo "ERROR: Could not read instance ID from IMDSv2. Exiting."
      exit 1
    fi
    stackId=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=${instanceId}" "Name=key,Values=aws:cloudformation:stack-id" --query "Tags[0].Value" --output text)
    if [[ -z "${stackId}" || "${stackId}" == "None" ]]; then
      echo "ERROR: Could not read aws:cloudformation:stack-id tag from instance ${instanceId}. Exiting."
      exit 1
    fi
    coreMembers=""
    for attempt in $(seq 1 30); do
      asgNames=$(aws autoscaling describe-auto-scaling-groups --region "$region" --query "AutoScalingGroups[?Tags[?Key=='StackID' && Value=='${stackId}'] && Tags[?Key=='Role' && Value=='neo4j-cluster-node']].AutoScalingGroupName" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | grep -v '^None$' | xargs || true)
      if [[ -n "${asgNames}" ]]; then
        instanceIds=$(aws autoscaling describe-auto-scaling-groups --region "$region" --auto-scaling-group-names ${asgNames} --query "AutoScalingGroups[].Instances[].InstanceId" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | grep -v '^None$' | xargs || true)
        if [[ -n "${instanceIds}" ]]; then
          coreMembers=$(aws ec2 describe-instances --region "$region" --instance-ids ${instanceIds} --query "Reservations[].Instances[].PrivateIpAddress" --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' | grep -v '^None$' | awk '{print $1":6000"}' | paste -sd, || true)
        fi
      fi
      foundCount=0
      [[ -n "${coreMembers}" ]] && foundCount=$(echo "${coreMembers}" | awk -F, '{print NF}')
      [[ ${foundCount} -ge ${nodeCount} ]] && break
      echo "Peer discovery attempt ${attempt}/30: found ${foundCount}/${nodeCount} members, retrying in 10s..."
      sleep 10
    done
    if [[ -z "${coreMembers}" ]]; then
      echo "ERROR: Peer discovery failed after 5 minutes. Exiting."
      exit 1
    fi
    echo "CoreMembers = ${coreMembers}"
    set_neo4j_conf dbms.cluster.discovery.resolver_type LIST
    set_neo4j_conf dbms.cluster.endpoints "${coreMembers}"
  fi
  if [ -n "${boltCertArn}" ]; then
    command -v jq >/dev/null || dnf install -y jq
    mkdir -p /var/lib/neo4j/certificates/bolt
    local _secret_json
    _secret_json=$(aws secretsmanager get-secret-value --region "${region}" \
      --secret-id "${boltCertArn}" --query SecretString --output text)
    if ! echo "${_secret_json}" | jq -e 'has("certificate") and has("private_key")' >/dev/null; then
      echo "ERROR: Secret ${boltCertArn} must be JSON with fields 'certificate' (PEM) and 'private_key' (PEM). Exiting." >&2
      exit 1
    fi
    umask 077
    echo "${_secret_json}" | jq -r '.private_key' > /var/lib/neo4j/certificates/bolt/private.key
    echo "${_secret_json}" | jq -r '.certificate' > /var/lib/neo4j/certificates/bolt/public.crt
    umask 022
    unset _secret_json
    chown -R neo4j:neo4j /var/lib/neo4j/certificates
    chmod 600 /var/lib/neo4j/certificates/bolt/private.key
    chmod 644 /var/lib/neo4j/certificates/bolt/public.crt
    set_neo4j_conf dbms.ssl.policy.bolt.enabled true
    set_neo4j_conf dbms.ssl.policy.bolt.base_directory /var/lib/neo4j/certificates/bolt
    set_neo4j_conf dbms.ssl.policy.bolt.private_key private.key
    set_neo4j_conf dbms.ssl.policy.bolt.public_certificate public.crt
    set_neo4j_conf dbms.ssl.policy.bolt.client_auth NONE
    set_neo4j_conf server.bolt.tls_level REQUIRED
  fi
}
add_cypher_ip_blocklist() {
  set_neo4j_conf internal.dbms.cypher_ip_blocklist "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.169.0/24,fc00::/7,fe80::/10,ff00::/8"
}
start_neo4j() {
  echo "Starting Neo4j..."
  service neo4j start
  # IS_FIRST_BOOT gates this: on replacement boots the auth DB already
  # exists on the retained volume, so skipping preserves any post-deploy
  # password changes the customer made.
  if [[ "${IS_FIRST_BOOT}" == "true" ]]; then
    neo4j-admin dbms set-initial-password "${password}"
  fi
}
install_cloudwatch_agent() {
  echo "Installing CloudWatch agent..."
  yum install -y amazon-cloudwatch-agent
  cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWCONFIG
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/neo4j/security.log",
            "log_group_name": "/neo4j/${stackName}/application",
            "log_stream_name": "{instance_id}/security",
            "retention_in_days": 90
          },
          {
            "file_path": "/var/log/neo4j/debug.log",
            "log_group_name": "/neo4j/${stackName}/application",
            "log_stream_name": "{instance_id}/debug",
            "retention_in_days": 90
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "/neo4j/${stackName}/application",
            "log_stream_name": "{instance_id}/cloud-init-output",
            "retention_in_days": 90
          }
        ]
      }
    }
  }
}
CWCONFIG
  /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
}
install_cloudwatch_agent
dnf install -y python3.11 unzip
dnf remove -y awscli 2>/dev/null || true
ARCH=$(uname -m)
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws
pin_neo4j_user
attach_and_mount_data_volume
install_neo4j_from_yum
extension_config
build_neo4j_conf_file
add_cypher_ip_blocklist
start_neo4j
# cfn-signal shebang (#!/usr/bin/python3 -s) requires cfnbootstrap under python3.9;
# switch the default only after signaling so cfn-signal can find its dependencies.
cfn-signal --success true --stack "$stackName" --resource "$logicalId" --region "$region"
alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 100
