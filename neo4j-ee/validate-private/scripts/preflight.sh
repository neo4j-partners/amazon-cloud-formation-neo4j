#!/usr/bin/env bash
# preflight.sh — Check that the stack and bastion are ready before running validate-private
#
# Checks (in order):
#   1. CloudFormation stack status = CREATE_COMPLETE
#   2. Bastion SSM PingStatus = Online
#   3. neo4j Python driver installed on bastion  (python3 -c "import neo4j")
#   4. cypher-shell installed on bastion
#   5. Secrets Manager secret exists
#   6. All 8 SSM config parameters exist under /neo4j-ee/<stack>/
#
# Usage: ./scripts/preflight.sh [stack-name]
# Typical runtime: 15-30s. Exits 0 only if all checks pass.

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

_cfn_complete() {
  local status
  status=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --region "${REGION}" \
    --query "Stacks[0].StackStatus" \
    --output text)
  [ "$status" = "CREATE_COMPLETE" ]
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

_neo4j_driver_installed() { _send_and_wait "python3 -c 'import neo4j; print(neo4j.__version__)'"; }
_cypher_shell_installed()  { _send_and_wait "cypher-shell --version"; }

_secret_exists() {
  aws secretsmanager describe-secret \
    --secret-id "neo4j/${STACK_NAME}/password" \
    --region "${REGION}" \
    --query "Name" \
    --output text >/dev/null
}

_ssm_params_exist() {
  local count
  count=$(aws ssm get-parameters-by-path \
    --path "/neo4j-ee/${STACK_NAME}/" \
    --region "${REGION}" \
    --query "length(Parameters)" \
    --output text)
  [ "${count}" -ge 8 ]
}

_check "Stack status = CREATE_COMPLETE"                     _cfn_complete
_check "Bastion SSM PingStatus = Online"                    _ssm_online
_check "neo4j Python driver installed on bastion"           _neo4j_driver_installed
_check "cypher-shell installed on bastion"                  _cypher_shell_installed
_check "Secret 'neo4j/${STACK_NAME}/password' exists"       _secret_exists
_check "All 8 SSM config params under /neo4j-ee/${STACK_NAME}/" _ssm_params_exist

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
