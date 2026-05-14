export IS_FIRST_BOOT=false

_token=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
_instance_id=$(curl -s -H "X-aws-ec2-metadata-token: $_token" http://169.254.169.254/latest/meta-data/instance-id)
_az=$(curl -s -H "X-aws-ec2-metadata-token: $_token" http://169.254.169.254/latest/meta-data/placement/availability-zone)

# ERR traps do not run for explicit `exit 1`, so fail() signals CloudFormation
# before exiting to avoid waiting for the ASG signal timeout.
fail() {
  echo "ERROR: $*" >&2
  if [[ -n "${logicalId:-}" ]]; then
    cfn-signal --success false --stack "$stackName" --resource "$logicalId" --region "$region" || true
  fi
  exit 1
}

[[ -n "${_instance_id}" && -n "${_az}" ]] || fail "IMDSv2 metadata unavailable."
logicalId=$(aws ec2 describe-tags --region "$region" --filters "Name=resource-id,Values=${_instance_id}" "Name=key,Values=aws:cloudformation:logical-id" --query "Tags[0].Value" --output text 2>/dev/null || true)
trap 'if [[ -n "${logicalId:-}" ]]; then cfn-signal --success false --stack "$stackName" --resource "$logicalId" --region "$region"; fi' ERR
_stack_id=$(aws ec2 describe-tags --region "$region" \
  --filters "Name=resource-id,Values=${_instance_id}" "Name=key,Values=aws:cloudformation:stack-id" \
  --query "Tags[0].Value" --output text 2>/dev/null || true)
[[ -n "${_stack_id}" && "${_stack_id}" != "None" ]] || fail "stack-id tag missing."

password=$(aws secretsmanager get-secret-value \
  --secret-id "neo4j/${stackName}/password" \
  --query SecretString --output text \
  --region "${region}")

# include partials/set-neo4j-conf.sh

# include partials/attach-data-volume.sh

# include partials/install-license.sh

# include partials/install-neo4j.sh

# include partials/install-plugins.sh

# include partials/configure-neo4j.sh

# include partials/configure-cloudwatch.sh

install_cloudwatch_agent
attach_and_mount_data_volume
install_neo4j_from_yum
install_apoc
if [[ "${installBloom}" == "true" ]]; then
  install_plugin Bloom "bloom-plugin-*.jar"
  [[ -n "${bloomLicenseSecretArn}" ]] || fail "InstallBloom=true requires BloomLicenseSecretArn to be set."
  fetch_and_install_license "${bloomLicenseSecretArn}" /var/lib/neo4j/licenses/neo4j-bloom.license "Bloom"
fi
if [[ "${installGDS}" == "true" ]]; then
  install_plugin GDS "neo4j-graph-data-science-*.jar"
  [[ -n "${gdsLicenseSecretArn}" ]] || fail "InstallGDS=true requires GdsLicenseSecretArn to be set."
  fetch_and_install_license "${gdsLicenseSecretArn}" /var/lib/neo4j/licenses/neo4j-gds.license "GDS"
fi
extension_config
build_neo4j_conf_file
start_neo4j
# cfn-signal shebang (#!/usr/bin/python3 -s) requires cfnbootstrap under python3.9;
# switch the default only after signaling so cfn-signal can find its dependencies.
cfn-signal --success true --stack "$stackName" --resource "$logicalId" --region "$region"
alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 100
