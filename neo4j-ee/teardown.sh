#!/bin/bash
# teardown.sh — Delete a Neo4j EE CloudFormation stack and clean up resources
#
# Reads .deploy/<stack-name>.txt (written by deploy.sh) to determine the stack
# name, region, SSM parameter path, and any copied AMI to clean up.
#
# Usage:
#   ./teardown.sh [--delete-volumes] [stack-name]
#
# If stack-name is omitted, uses the most recently modified file in .deploy/.
# --delete-volumes: after stack deletion, permanently delete the retained EBS
#   data volumes. Without this flag the volumes are printed but left intact.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"

DELETE_VOLUMES=false

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="${SCRIPT_DIR}/.deploy"

# ---------------------------------------------------------------------------
# Parse arguments: [--delete-volumes] [stack-name]
# ---------------------------------------------------------------------------
STACK_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete-volumes)
      DELETE_VOLUMES=true
      shift
      ;;
    -*)
      echo "ERROR: Unknown option '$1'." >&2
      echo "Usage: $0 [--delete-volumes] [stack-name]" >&2
      exit 1
      ;;
    *)
      if [ -z "${STACK_ARG}" ]; then
        STACK_ARG="$1"
      else
        echo "ERROR: Unexpected argument '$1'." >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Helper: read a value from a "Key = Value" file
# ---------------------------------------------------------------------------
read_field() {
  local file="$1"
  local key="$2"
  grep "^${key}" "$file" | sed 's/^[^=]*= *//' | tr -d '\r'
}

force_delete_secret() {
  local secret_id="$1"
  aws secretsmanager delete-secret \
    --region "${REGION}" \
    --secret-id "${secret_id}" \
    --force-delete-without-recovery 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Resolve the outputs file
# ---------------------------------------------------------------------------
if [ -n "${STACK_ARG}" ]; then
  OUTPUTS_FILE="${DEPLOY_DIR}/${STACK_ARG}.txt"
elif [ -d "${DEPLOY_DIR}" ]; then
  OUTPUTS_FILE=$(ls -t "${DEPLOY_DIR}"/*.txt 2>/dev/null | head -1 || true)
else
  OUTPUTS_FILE=""
fi

if [ -z "${OUTPUTS_FILE}" ] || [ ! -f "${OUTPUTS_FILE}" ]; then
  echo "ERROR: No deployment found." >&2
  if [ -n "${STACK_ARG}" ]; then
    echo "File not found: ${DEPLOY_DIR}/${STACK_ARG}.txt" >&2
  else
    echo "No .txt files in ${DEPLOY_DIR}/" >&2
  fi
  echo "Usage: $0 [--delete-volumes] [stack-name]" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
STACK_NAME=$(read_field "${OUTPUTS_FILE}" "StackName")
REGION=$(read_field "${OUTPUTS_FILE}" "Region")
SSM_PARAM_PATH=$(read_field "${OUTPUTS_FILE}" "SSMParamPath" 2>/dev/null || true)
COPIED_AMI_ID=$(read_field "${OUTPUTS_FILE}" "CopiedAmiId" 2>/dev/null || true)
STACK_ID=$(read_field "${OUTPUTS_FILE}" "StackID" 2>/dev/null || true)

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
# Step 2b: Force-delete the Neo4j password secret (Private mode only)
#
# The stack owns AWS::SecretsManager::Secret at neo4j/<stack-name>/password.
# CFN's stack delete schedules the secret for deletion with a 30-day recovery
# window, which blocks re-deploying the same stack name until the window
# expires. Force-delete purges it immediately. --force-delete-without-recovery
# works on secrets already in "scheduled deletion" state, so running this
# after stack delete is safe and idempotent.
# ---------------------------------------------------------------------------
PASSWORD_SECRET_NAME="neo4j/${STACK_NAME}/password"
echo ""
echo "Force-deleting password secret ${PASSWORD_SECRET_NAME} (if present)..."
force_delete_secret "${PASSWORD_SECRET_NAME}"
echo "Password secret cleanup done."

# ---------------------------------------------------------------------------
# Step 2c: Force-delete the Bolt TLS cert secret (--tls deploys only)
# ---------------------------------------------------------------------------
BOLT_TLS_SECRET_ARN=$(read_field "${OUTPUTS_FILE}" "BoltTlsSecretArn" 2>/dev/null || true)
if [ -n "${BOLT_TLS_SECRET_ARN}" ]; then
  echo ""
  echo "Force-deleting Bolt TLS cert secret ${BOLT_TLS_SECRET_ARN}..."
  force_delete_secret "${BOLT_TLS_SECRET_ARN}"
  echo "Bolt TLS cert secret cleanup done."
fi

# ---------------------------------------------------------------------------
# Step 2d: Handle retained EBS data volumes
#
# Volumes have DeletionPolicy: Retain so they survive stack deletion by design.
# Default: enumerate them and print a rerun hint so the operator can decide.
# --delete-volumes: permanently delete each volume.
# ---------------------------------------------------------------------------
if [ -n "${STACK_ID}" ]; then
  echo ""
  echo "Looking up retained data volumes for StackID=${STACK_ID}..."
  VOLUME_IDS=$(aws ec2 describe-volumes \
    --region "${REGION}" \
    --filters \
      "Name=tag:StackID,Values=${STACK_ID}" \
      "Name=tag:Role,Values=neo4j-cluster-data" \
    --query "Volumes[*].[VolumeId,Size,AvailabilityZone,CreateTime]" \
    --output text 2>/dev/null || true)

  if [ -z "${VOLUME_IDS}" ]; then
    echo "No retained data volumes found."
  elif [ "${DELETE_VOLUMES}" = true ]; then
    echo "Deleting retained data volumes..."
    while IFS=$'\t' read -r vol_id size az created; do
      echo "  Deleting ${vol_id} (${size}GB, ${az}, created ${created})..."
      aws ec2 delete-volume --region "${REGION}" --volume-id "${vol_id}" \
        || echo "  WARNING: Failed to delete ${vol_id} — check AWS console."
      echo "  Deleted ${vol_id}."
    done <<< "${VOLUME_IDS}"
    echo "All data volumes deleted."
  else
    echo "Retained data volumes (not deleted — pass --delete-volumes to remove):"
    while IFS=$'\t' read -r vol_id size az created; do
      echo "  ${vol_id}  ${size}GB  ${az}  created ${created}"
    done <<< "${VOLUME_IDS}"
    echo ""
    echo "To delete: ./teardown.sh --delete-volumes ${STACK_NAME}"
  fi
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
CA_BUNDLE="${SCRIPT_DIR}/sample-private-app/lambda/neo4j-ca.crt"
if [ -f "${CA_BUNDLE}" ]; then
  echo ""
  echo "Removing staged CA bundle ${CA_BUNDLE}..."
  rm -f "${CA_BUNDLE}"
  echo "CA bundle removed."
fi

echo ""
echo "Removing ${OUTPUTS_FILE}..."
rm -f "${OUTPUTS_FILE}"

echo ""
echo "============================================="
echo "  Teardown complete."
echo "============================================="
