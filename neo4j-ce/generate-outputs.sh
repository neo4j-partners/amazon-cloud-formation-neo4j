#!/bin/bash
# generate-outputs.sh — Create a .deploy/<stack-name>.txt file from any
# deployed Neo4j CE CloudFormation stack (including Marketplace deploys).
#
# This bridges stacks created outside of deploy.sh so that test-stack.sh
# and test_ce/ can be used against them.
#
# Usage:
#   ./generate-outputs.sh --stack-name <name> --region <region> [--password <password>]
#
# If --password is omitted, prompts interactively.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-marketplace}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Helper: read a value from a "Key = Value" file
# ---------------------------------------------------------------------------
read_field() {
  local file="$1"
  local key="$2"
  grep "^${key}" "$file" | sed 's/^[^=]*= *//' | tr -d '\r'
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
STACK_NAME=""
REGION=""
PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --password)
      PASSWORD="$2"
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument '$1'." >&2
      echo "Usage: $0 --stack-name <name> --region <region> [--password <password>]" >&2
      exit 1
      ;;
  esac
done

if [ -z "${STACK_NAME}" ] || [ -z "${REGION}" ]; then
  echo "ERROR: --stack-name and --region are required." >&2
  echo "Usage: $0 --stack-name <name> --region <region> [--password <password>]" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate the stack exists and is healthy
# ---------------------------------------------------------------------------
echo "Querying stack ${STACK_NAME} in ${REGION}..."

STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].StackStatus" \
  --output text 2>/dev/null) || {
    echo "ERROR: Stack '${STACK_NAME}' not found in ${REGION}." >&2
    exit 1
  }

if [[ "${STACK_STATUS}" != "CREATE_COMPLETE" && "${STACK_STATUS}" != "UPDATE_COMPLETE" ]]; then
  echo "ERROR: Stack status is ${STACK_STATUS} (expected CREATE_COMPLETE or UPDATE_COMPLETE)." >&2
  exit 1
fi

echo "  Stack status: ${STACK_STATUS}"

# ---------------------------------------------------------------------------
# Resolve password (before any file writes)
# ---------------------------------------------------------------------------
if [ -z "${PASSWORD}" ]; then
  if [ -t 0 ]; then
    read -r -s -p "Enter neo4j password: " PASSWORD
    echo ""
  else
    echo "ERROR: No password provided and stdin is not a terminal." >&2
    echo "Use --password <password> when running non-interactively." >&2
    exit 1
  fi
fi

if [ -z "${PASSWORD}" ]; then
  echo "ERROR: Password cannot be empty." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fetch CloudFormation outputs and write to .deploy/<stack-name>.txt
# ---------------------------------------------------------------------------
echo "Fetching stack outputs and parameters..."

mkdir -p "${SCRIPT_DIR}/.deploy"
OUTPUTS_FILE="${SCRIPT_DIR}/.deploy/${STACK_NAME}.txt"

# CloudFormation outputs — same write pattern as deploy.sh
aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output text | while read -r key value; do
    printf "%-20s = %s\n" "$key" "$value"
  done > "${OUTPUTS_FILE}"

# Validate required outputs were written
for req in Neo4jBrowserURL Neo4jURI Username; do
  if ! grep -q "^${req}" "${OUTPUTS_FILE}"; then
    echo "ERROR: Required CloudFormation output '${req}' not found in stack." >&2
    rm -f "${OUTPUTS_FILE}"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Fetch CloudFormation parameters for deploy context
# ---------------------------------------------------------------------------
# Password is NoEcho so CFN returns **** — we use the prompted value instead.
# Parameter values we care about (InstallAPOC, InstanceType, DiskSize,
# DataDiskSize) never contain spaces, so awk $2 is safe.
CFN_PARAMS=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}" \
  --query "Stacks[0].Parameters[*].[ParameterKey,ParameterValue]" \
  --output text 2>/dev/null || true)

# Helper: extract a parameter value ($1=key, $2=default)
get_param() {
  local val
  val=$(printf '%s\n' "${CFN_PARAMS}" | awk -v k="$1" '$1==k{print $2}')
  echo "${val:-$2}"
}

# Append deploy context (values not in CloudFormation outputs)
{
  printf "%-20s = %s\n" "StackName" "${STACK_NAME}"
  printf "%-20s = %s\n" "Region" "${REGION}"
  printf "%-20s = %s\n" "Password" "${PASSWORD}"
  printf "%-20s = %s\n" "InstallAPOC" "$(get_param InstallAPOC yes)"
  printf "%-20s = %s\n" "InstanceType" "$(get_param InstanceType t3.medium)"
  printf "%-20s = %s\n" "DiskSize" "$(get_param DiskSize 20)"
  printf "%-20s = %s\n" "DataDiskSize" "$(get_param DataDiskSize 30)"
  printf "%-20s = %s\n" "VolumeType" "gp3"
} | tee -a "${OUTPUTS_FILE}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
ENDPOINT=$(read_field "${OUTPUTS_FILE}" "Neo4jBrowserURL")

echo ""
echo "============================================="
echo "  Outputs file generated"
echo "============================================="
echo "  File:     ${OUTPUTS_FILE}"
echo "  Stack:    ${STACK_NAME}"
echo "  Region:   ${REGION}"
echo "  Endpoint: ${ENDPOINT}"
echo "============================================="
echo ""
echo "To test (bash):   ./test-stack.sh --stack ${STACK_NAME}"
echo "To test (Python): cd test_ce && uv run test-ce --stack ${STACK_NAME}"
