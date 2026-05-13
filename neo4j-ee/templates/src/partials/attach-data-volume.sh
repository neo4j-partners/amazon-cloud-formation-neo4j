attach_and_mount_data_volume() {
  echo "Attaching and mounting data volume..."
  local _token
  _token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  local _instance_id
  _instance_id=$(curl -s -H "X-aws-ec2-metadata-token: $_token" http://169.254.169.254/latest/meta-data/instance-id)
  local _az
  _az=$(curl -s -H "X-aws-ec2-metadata-token: $_token" http://169.254.169.254/latest/meta-data/placement/availability-zone)
  if [[ -z "${_instance_id}" || -z "${_az}" ]]; then
    fail "Could not read instance metadata from IMDSv2."
  fi
  local _stack_id
  _stack_id=$(aws ec2 describe-tags --region "$region" \
    --filters "Name=resource-id,Values=${_instance_id}" \
              "Name=key,Values=aws:cloudformation:stack-id" \
    --query "Tags[0].Value" --output text)
  if [[ -z "${_stack_id}" || "${_stack_id}" == "None" ]]; then
    fail "Could not read aws:cloudformation:stack-id tag."
  fi
  local _vols _vol_count _data_vol_id
  _vols=$(aws ec2 describe-volumes --region "$region" \
    --filters "Name=tag:StackID,Values=${_stack_id}" \
              "Name=tag:Role,Values=neo4j-cluster-data" \
              "Name=availability-zone,Values=${_az}" \
    --query "Volumes[*].VolumeId" --output text)
  _vol_count=$(echo "${_vols}" | wc -w | xargs)
  if [[ "${_vol_count}" -ne 1 ]]; then
    fail "Expected 1 data volume in AZ ${_az}, found ${_vol_count}."
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
      fail "Volume ${_data_vol_id} did not become available after 10 min (state=${_vol_top_state})."
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
    fail "Could not attach volume ${_data_vol_id} to ${_instance_id}."
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
    fail "Volume ${_data_vol_id} did not reach 'attached' within 2 minutes."
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
    fail "Could not resolve NVMe device for volume ${_data_vol_id} after retries."
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
    fail "Could not read UUID from ${_data_dev}."
  fi
  mkdir -p /var/lib/neo4j/data
  echo "UUID=${_uuid}  /var/lib/neo4j/data  xfs  defaults,nofail,noatime,x-systemd.device-timeout=30  0 2" >> /etc/fstab
  mount /var/lib/neo4j/data
  echo "Data volume mounted at /var/lib/neo4j/data"
  if [[ "${IS_FIRST_BOOT}" == "true" ]]; then
    chown neo4j:neo4j /var/lib/neo4j/data
  fi
}
