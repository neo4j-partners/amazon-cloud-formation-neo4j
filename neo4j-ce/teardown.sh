#!/bin/bash
# teardown.sh — Delete the Neo4j CE CloudFormation stack and clean up resources
#
# Reads stack-outputs.txt (written by deploy.sh) to determine the stack name,
# region, and SSM parameter path, then deletes everything.
#
# Usage:
#   ./teardown.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUTS_FILE="${SCRIPT_DIR}/stack-outputs.txt"

# ---------------------------------------------------------------------------
# Helper: read a value from a "Key = Value" file
# ---------------------------------------------------------------------------
read_field() {
  local file="$1"
  local key="$2"
  grep "^${key}" "$file" | sed 's/^[^=]*= *//' | tr -d '\r'
}

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
if [ ! -f "${OUTPUTS_FILE}" ]; then
  echo "ERROR: ${OUTPUTS_FILE} not found." >&2
  echo "Nothing to tear down (no deploy.sh output found)." >&2
  exit 1
fi

STACK_NAME=$(read_field "${OUTPUTS_FILE}" "StackName")
REGION=$(read_field "${OUTPUTS_FILE}" "Region")
SSM_PARAM_PATH=$(read_field "${OUTPUTS_FILE}" "SSMParamPath")

if [ -z "${STACK_NAME}" ] || [ -z "${REGION}" ]; then
  echo "ERROR: Could not read StackName or Region from ${OUTPUTS_FILE}." >&2
  exit 1
fi

echo "=== Neo4j CE Stack Teardown ==="
echo ""
echo "  Stack:     ${STACK_NAME}"
echo "  Region:    ${REGION}"
echo "  SSM Param: ${SSM_PARAM_PATH}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Delete the CloudFormation stack
# ---------------------------------------------------------------------------
echo "Deleting stack ${STACK_NAME}..."
aws cloudformation delete-stack \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}"

echo "Waiting for stack deletion to complete (this takes a few minutes)..."
aws cloudformation wait stack-delete-complete \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}"

echo "Stack deleted."

# ---------------------------------------------------------------------------
# Step 2: Delete the SSM parameter created by deploy.sh
# ---------------------------------------------------------------------------
if [ -n "${SSM_PARAM_PATH}" ]; then
  echo ""
  echo "Deleting SSM parameter ${SSM_PARAM_PATH}..."
  aws ssm delete-parameter \
    --region "${REGION}" \
    --name "${SSM_PARAM_PATH}" 2>/dev/null || true
  echo "SSM parameter deleted."
fi

# ---------------------------------------------------------------------------
# Step 3: Clean up local files
# ---------------------------------------------------------------------------
echo ""
echo "Removing ${OUTPUTS_FILE}..."
rm -f "${OUTPUTS_FILE}"

echo ""
echo "============================================="
echo "  Teardown complete."
echo "============================================="
