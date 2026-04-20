#!/usr/bin/env bash
# preflight.sh — Check that the stack and bastion are ready before running validate-private
#
# Checks (in order):
#   1.  CloudFormation stack status = CREATE_COMPLETE or UPDATE_COMPLETE
#   2.  Bastion SSM PingStatus = Online
#   3.  neo4j Python driver installed on bastion  (python3.11 -c "import neo4j")
#   4.  cypher-shell installed on bastion
#   5.  Secrets Manager secret exists
#   6.  Contract SSM params (5 named: vpc-id, nlb-dns, external-sg-id,
#         password-secret-arn, vpc-endpoint-sg-id)
#   7.  Operational SSM params (4 named: region, stack-name,
#         private-subnet-1-id, private-subnet-2-id) [informational — WARN, not FAIL]
#   8.  VPC interface endpoints exist (secretsmanager, logs, ssm, ssmmessages)
#   9.  Endpoint reachable: secretsmanager
#   10. Endpoint reachable: logs
#   11. Endpoint reachable: ssm
#   12. Endpoint reachable: ssmmessages
#
# Usage: ./scripts/preflight.sh [stack-name]
# Typical runtime: 45-75s. Exits 0 only if all required checks pass (check 7 is informational).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

OUTPUTS_FILE=$(resolve_stack "${1:-}")
STACK_NAME=$(read_field "$OUTPUTS_FILE" "StackName")
REGION=$(read_field "$OUTPUTS_FILE" "Region")
BASTION_ID=$(read_field "$OUTPUTS_FILE" "Neo4jOperatorBastionId")

echo "=== Preflight Checks ==="
echo ""
echo "  Stack:   ${STACK_NAME}"
echo "  Region:  ${REGION}"
echo "  Bastion: ${BASTION_ID}"
echo ""

PASS_COUNT=0
FAIL_COUNT=0

_check() {
  local label="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "  [PASS] ${label}"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "  [FAIL] ${label}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# Informational check — prints [INFO] or [WARN] but never increments FAIL_COUNT.
_info_check() {
  local label="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "  [INFO] ${label}"
  else
    echo "  [WARN] ${label}"
  fi
}

_cfn_complete() {
  local status
  status=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].StackStatus" \
    --output text)
  [[ "$status" == "CREATE_COMPLETE" || "$status" == "UPDATE_COMPLETE" ]]
}

_ssm_online() {
  local ping
  ping=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${BASTION_ID}" \
    --region "${REGION}" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text 2>/dev/null)
  [ "$ping" = "Online" ]
}

# Send a one-shot shell command to the bastion and wait up to 30s for success.
_send_and_wait() {
  local cmd="$1"
  local cmd_id i status

  cmd_id=$(aws ssm send-command \
    --instance-ids "${BASTION_ID}" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"${cmd}\"]" \
    --region "${REGION}" \
    --query "Command.CommandId" \
    --output text)

  for i in $(seq 1 15); do
    status=$(aws ssm get-command-invocation \
      --command-id "${cmd_id}" \
      --instance-id "${BASTION_ID}" \
      --region "${REGION}" \
      --query "Status" \
      --output text 2>/dev/null || echo "Pending")
    [ "$status" = "Success" ] && return 0
    [[ "$status" == "Failed" || "$status" == "Cancelled" || "$status" == "TimedOut" ]] && return 1
    sleep 2
  done
  return 1
}

_neo4j_driver_installed() { _send_and_wait "python3.11 -c 'import neo4j; print(neo4j.__version__)'"; }
_cypher_shell_installed()  { _send_and_wait "cypher-shell --version"; }

_secret_exists() {
  aws secretsmanager describe-secret \
    --secret-id "neo4j/${STACK_NAME}/password" \
    --region "${REGION}" \
    --query "Name" \
    --output text >/dev/null
}

_contract_params_exist() {
  local params=(
    "vpc-id"
    "nlb-dns"
    "external-sg-id"
    "password-secret-arn"
    "vpc-endpoint-sg-id"
  )
  for param in "${params[@]}"; do
    aws ssm get-parameter \
      --name "/neo4j-ee/${STACK_NAME}/${param}" \
      --region "${REGION}" \
      --query "Parameter.Value" \
      --output text >/dev/null 2>&1 || return 1
  done
}

_operational_params_exist() {
  local params=(
    "region"
    "stack-name"
    "private-subnet-1-id"
    "private-subnet-2-id"
  )
  for param in "${params[@]}"; do
    aws ssm get-parameter \
      --name "/neo4j-ee/${STACK_NAME}/${param}" \
      --region "${REGION}" \
      --query "Parameter.Value" \
      --output text >/dev/null 2>&1 || return 1
  done
}

# VPC_ID is read from SSM after check 6 passes and used by checks 8-12.
_vpc_endpoints_exist() {
  [ -n "${VPC_ID}" ] || return 1
  local services
  services=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=vpc-endpoint-state,Values=available" \
    --region "${REGION}" \
    --query "VpcEndpoints[].ServiceName" \
    --output text 2>/dev/null)
  for svc in \
    "com.amazonaws.${REGION}.secretsmanager" \
    "com.amazonaws.${REGION}.logs" \
    "com.amazonaws.${REGION}.ssm" \
    "com.amazonaws.${REGION}.ssmmessages"; do
    echo "${services}" | tr '\t' '\n' | grep -qxF "${svc}" || return 1
  done
}

# Reachability probes: curl the regional endpoint hostname via the bastion.
# Expected result: HTTP 400, 403, or 404 (endpoint refuses unsigned requests —
# different service control planes return different 4xx codes on the root path).
# A timeout (000) means SG or DNS is broken; 2xx means PrivateDNS is not in
# effect and the request reached the public endpoint.
_endpoint_reachable_secretsmanager() {
  _send_and_wait "curl -m 5 -sSo /dev/null -w '%{http_code}' https://secretsmanager.${REGION}.amazonaws.com/ | grep -qE '^(400|403|404)$'"
}
_endpoint_reachable_logs() {
  _send_and_wait "curl -m 5 -sSo /dev/null -w '%{http_code}' https://logs.${REGION}.amazonaws.com/ | grep -qE '^(400|403|404)$'"
}
_endpoint_reachable_ssm() {
  _send_and_wait "curl -m 5 -sSo /dev/null -w '%{http_code}' https://ssm.${REGION}.amazonaws.com/ | grep -qE '^(400|403|404)$'"
}
_endpoint_reachable_ssmmessages() {
  _send_and_wait "curl -m 5 -sSo /dev/null -w '%{http_code}' https://ssmmessages.${REGION}.amazonaws.com/ | grep -qE '^(400|403|404)$'"
}

_check "Stack status = CREATE_COMPLETE or UPDATE_COMPLETE"  _cfn_complete
_check "Bastion SSM PingStatus = Online"                    _ssm_online
_check "neo4j Python driver installed on bastion"           _neo4j_driver_installed
_check "cypher-shell installed on bastion"                  _cypher_shell_installed
_check "Secret 'neo4j/${STACK_NAME}/password' exists"       _secret_exists
_check "Contract SSM params: vpc-id, nlb-dns, external-sg-id, password-secret-arn, vpc-endpoint-sg-id" \
  _contract_params_exist
_info_check "Operational SSM params: region, stack-name, private-subnet-1-id, private-subnet-2-id" \
  _operational_params_exist

# Read VPC_ID from the contract SSM param. Order is load-bearing: the contract
# params check above must pass first so a missing /vpc-id surfaces as "contract
# param missing" rather than a confusing "no such VPC" error in checks 8-12.
VPC_ID=$(aws ssm get-parameter \
  --name "/neo4j-ee/${STACK_NAME}/vpc-id" \
  --region "${REGION}" \
  --query "Parameter.Value" \
  --output text 2>/dev/null || echo "")

_check "VPC interface endpoints: secretsmanager, logs, ssm, ssmmessages" \
  _vpc_endpoints_exist
_check "Endpoint reachable: secretsmanager.${REGION}.amazonaws.com" \
  _endpoint_reachable_secretsmanager
_check "Endpoint reachable: logs.${REGION}.amazonaws.com" \
  _endpoint_reachable_logs
_check "Endpoint reachable: ssm.${REGION}.amazonaws.com" \
  _endpoint_reachable_ssm
_check "Endpoint reachable: ssmmessages.${REGION}.amazonaws.com" \
  _endpoint_reachable_ssmmessages

echo ""
echo "  ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  echo ""
  echo "  Troubleshooting:"
  echo "    Bastion not ready? UserData may still be running — wait 2-3 min and retry."
  echo "    Check SSM status: aws ssm describe-instance-information \\"
  echo "      --filters Key=InstanceIds,Values=${BASTION_ID} --region ${REGION}"
  exit 1
fi

echo "  All checks passed."
