#!/bin/bash
# teardown.sh — Delete a Neo4j EE CloudFormation stack and clean up resources
#
# Reads .deploy/<stack-name>.txt (written by deploy.sh) to determine the stack
# name, region, SSM parameter path, and any copied AMI to clean up.
#
# Usage:
#   ./teardown.sh [stack-name]
#
# If stack-name is omitted, uses the most recently modified file in .deploy/.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="${SCRIPT_DIR}/.deploy"

# ---------------------------------------------------------------------------
# Helper: read a value from a "Key = Value" file
# ---------------------------------------------------------------------------
read_field() {
  local file="$1"
  local key="$2"
  grep "^${key}" "$file" | sed 's/^[^=]*= *//' | tr -d '\r'
}

# ---------------------------------------------------------------------------
# Resolve the outputs file
# ---------------------------------------------------------------------------
if [ $# -ge 1 ]; then
  OUTPUTS_FILE="${DEPLOY_DIR}/$1.txt"
elif [ -d "${DEPLOY_DIR}" ]; then
  OUTPUTS_FILE=$(ls -t "${DEPLOY_DIR}"/*.txt 2>/dev/null | head -1 || true)
else
  OUTPUTS_FILE=""
fi

if [ -z "${OUTPUTS_FILE}" ] || [ ! -f "${OUTPUTS_FILE}" ]; then
  echo "ERROR: No deployment found." >&2
  if [ $# -ge 1 ]; then
    echo "File not found: ${DEPLOY_DIR}/$1.txt" >&2
  else
    echo "No .txt files in ${DEPLOY_DIR}/" >&2
  fi
  echo "Usage: $0 [stack-name]" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
STACK_NAME=$(read_field "${OUTPUTS_FILE}" "StackName")
REGION=$(read_field "${OUTPUTS_FILE}" "Region")
SSM_PARAM_PATH=$(read_field "${OUTPUTS_FILE}" "SSMParamPath" 2>/dev/null || true)
COPIED_AMI_ID=$(read_field "${OUTPUTS_FILE}" "CopiedAmiId" 2>/dev/null || true)

if [ -z "${STACK_NAME}" ] || [ -z "${REGION}" ]; then
  echo "ERROR: Could not read StackName or Region from ${OUTPUTS_FILE}." >&2
  exit 1
fi

echo "=== Neo4j EE Stack Teardown ==="
echo ""
echo "  Stack:     ${STACK_NAME}"
echo "  Region:    ${REGION}"
if [ -n "${SSM_PARAM_PATH}" ]; then
  echo "  SSM Param: ${SSM_PARAM_PATH}"
fi
if [ -n "${COPIED_AMI_ID}" ]; then
  echo "  Copied AMI: ${COPIED_AMI_ID}"
fi
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
# Step 2: Delete the SSM parameter (local AMI mode only)
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
# Step 3: Clean up copied AMI (cross-region local AMI deploys only)
# ---------------------------------------------------------------------------
if [ -n "${COPIED_AMI_ID}" ]; then
  echo ""
  echo "Deregistering copied AMI ${COPIED_AMI_ID} in ${REGION}..."
  aws ec2 deregister-image \
    --region "${REGION}" \
    --image-id "${COPIED_AMI_ID}" 2>/dev/null || true

  echo "Deleting backing snapshots..."
  aws ec2 describe-snapshots \
    --region "${REGION}" \
    --filters "Name=description,Values=*${COPIED_AMI_ID}*" \
    --query "Snapshots[].SnapshotId" \
    --output text 2>/dev/null | while read -r snap_id; do
      if [ -n "${snap_id}" ]; then
        echo "  Deleting snapshot ${snap_id}..."
        aws ec2 delete-snapshot --region "${REGION}" --snapshot-id "${snap_id}" 2>/dev/null || true
      fi
    done
  echo "Copied AMI cleaned up."
fi

# ---------------------------------------------------------------------------
# Step 4: Clean up local files
# ---------------------------------------------------------------------------
echo ""
echo "Removing ${OUTPUTS_FILE}..."
rm -f "${OUTPUTS_FILE}"

echo ""
echo "============================================="
echo "  Teardown complete."
echo "============================================="
