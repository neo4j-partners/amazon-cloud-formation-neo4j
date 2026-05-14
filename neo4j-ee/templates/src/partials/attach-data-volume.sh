attach_and_mount_data_volume() {
  echo "Attaching data volume..."
  local vols vc vid uuid
  local dev=""
  vols=$(aws ec2 describe-volumes --region "$region" \
    --filters "Name=tag:StackID,Values=${_stack_id}" "Name=tag:Role,Values=neo4j-cluster-data" "Name=availability-zone,Values=${_az}" \
    --query "Volumes[*].VolumeId" --output text)
  vc=$(echo "${vols}" | wc -w | xargs)
  [[ "${vc}" -eq 1 ]] || fail "Expected 1 data volume in ${_az}, found ${vc}."
  vid="${vols}"
  echo "Data volume: ${vid}"
  local s=0 state=""
  while true; do
    state=$(aws ec2 describe-volumes --region "$region" --volume-ids "${vid}" --query "Volumes[0].State" --output text 2>/dev/null || echo unknown)
    [[ "${state}" != "available" ]] || break
    (( s < 600 )) || fail "Volume ${vid} not available after 10m (state=${state})."
    echo "  Volume state: ${state}, waiting..."
    sleep 10; s=$(( s + 10 ))
  done
  local ok=false
  for t in 1 2 3; do
    if aws ec2 attach-volume --region "$region" --volume-id "${vid}" --instance-id "${_instance_id}" --device /dev/sdf >/dev/null 2>&1; then
      ok=true; break
    fi
    sleep 5
  done
  [[ "${ok}" == "true" ]] || fail "attach-volume failed for ${vid}."
  local astate=""
  for i in $(seq 1 24); do
    astate=$(aws ec2 describe-volumes --region "$region" --volume-ids "${vid}" --query "Volumes[0].Attachments[0].State" --output text 2>/dev/null || true)
    [[ "${astate}" != "attached" ]] || break
    sleep 5
  done
  [[ "${astate}" == "attached" ]] || fail "Volume ${vid} not attached in 2m."
  local vid_serial
  vid_serial=$(echo "${vid}" | tr -d '-')
  for t in 1 2 3 4 5 6; do
    for d in /dev/nvme?n1; do
      [[ -b "$d" ]] || continue
      local d_serial
      d_serial=$(lsblk -no SERIAL "$d" 2>/dev/null | tr -d ' ')
      if [[ "$d_serial" == "$vid_serial" ]]; then
        dev="$d"; break 2
      fi
    done
    sleep 2
  done
  [[ -n "${dev}" && -b "${dev}" ]] || fail "Could not resolve NVMe device for ${vid}."
  if ! blkid "${dev}" > /dev/null 2>&1; then
    mkfs.xfs "${dev}"
    IS_FIRST_BOOT=true
  fi
  uuid=$(blkid -s UUID -o value "${dev}")
  [[ -n "${uuid}" ]] || fail "No UUID on ${dev}."
  mkdir -p /var/lib/neo4j/data
  echo "UUID=${uuid}  /var/lib/neo4j/data  xfs  defaults,nofail,noatime,x-systemd.device-timeout=30  0 2" >> /etc/fstab
  mount /var/lib/neo4j/data
  [[ "${IS_FIRST_BOOT}" != "true" ]] || chown neo4j:neo4j /var/lib/neo4j/data
}
