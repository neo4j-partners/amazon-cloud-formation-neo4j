#!/bin/bash
# force-delete-lambda-enis.sh — Delete stuck VPC ENIs for the Neo4j demo Lambda.
#
# VPC-attached Lambda functions create ENIs that CloudFormation must clean up
# on stack deletion. AWS can take 15-45 minutes to detach them. Running this
# script while the stack is in DELETE_IN_PROGRESS unblocks the deletion.
#
# Usage:
#   ./force-delete-lambda-enis.sh [ee-stack-name]
#
# If ee-stack-name is omitted, uses the most recently modified
# sample-private-app-*.json file in the parent neo4j-ee/.deploy/ directory.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/.deploy"

# ---------------------------------------------------------------------------
# Resolve the app outputs file
# ---------------------------------------------------------------------------
if [ $# -ge 1 ]; then
  APP_FILE="${DEPLOY_DIR}/sample-private-app-$1.json"
else
  APP_FILE=$(ls -t "${DEPLOY_DIR}"/sample-private-app-*.json 2>/dev/null | head -1 || true)
fi

if [ -z "${APP_FILE}" ] || [ ! -f "${APP_FILE}" ]; then
  echo "ERROR: No sample-private-app deployment found." >&2
  echo "Usage: $0 [ee-stack-name]" >&2
  exit 1
fi

FUNCTION_ARN=$(python3 -c "import json; d=json.load(open('${APP_FILE}')); print(d['function_arn'])")
REGION=$(python3 -c "import json; d=json.load(open('${APP_FILE}')); print(d['region'])")
FUNCTION_NAME="${FUNCTION_ARN##*:function:}"
ENI_DESC_PREFIX="AWS Lambda VPC ENI-${FUNCTION_NAME}"

echo "=== Force-Delete Lambda ENIs ==="
echo ""
echo "  Function: ${FUNCTION_NAME}"
echo "  Region:   ${REGION}"
echo "  ENI desc: ${ENI_DESC_PREFIX}*"
echo ""

# ---------------------------------------------------------------------------
# Find ENIs by description
# ---------------------------------------------------------------------------
ENIS=$(aws ec2 describe-network-interfaces \
  --region "${REGION}" \
  --filters "Name=description,Values=${ENI_DESC_PREFIX}*" \
  --query "NetworkInterfaces[*].{Id:NetworkInterfaceId,Status:Status}" \
  --output json)

COUNT=$(echo "${ENIS}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

if [ "${COUNT}" -eq 0 ]; then
  echo "No ENIs found matching this Lambda. They may already be deleted."
  exit 0
fi

echo "Found ${COUNT} ENI(s). Waiting for each to become available before deleting..."
echo ""

echo "${ENIS}" | python3 -c "
import json, sys
for eni in json.load(sys.stdin):
    print(eni['Id'], eni['Status'])
"
echo ""

# ---------------------------------------------------------------------------
# Wait for each ENI to reach 'available', then delete it
# ---------------------------------------------------------------------------
ENI_IDS=$(echo "${ENIS}" | python3 -c "
import json, sys
for eni in json.load(sys.stdin):
    print(eni['Id'])
")

for ENI_ID in ${ENI_IDS}; do
  echo -n "  ${ENI_ID}: waiting for available... "

  for i in $(seq 1 30); do
    STATUS=$(aws ec2 describe-network-interfaces \
      --region "${REGION}" \
      --network-interface-ids "${ENI_ID}" \
      --query "NetworkInterfaces[0].Status" \
      --output text 2>/dev/null || echo "deleted")

    if [ "${STATUS}" = "available" ]; then
      break
    elif [ "${STATUS}" = "deleted" ]; then
      echo "already deleted."
      break 2
    fi

    sleep 10
    echo -n "."
  done

  if [ "${STATUS}" = "available" ]; then
    aws ec2 delete-network-interface \
      --region "${REGION}" \
      --network-interface-id "${ENI_ID}"
    echo " deleted."
  elif [ "${STATUS}" != "deleted" ]; then
    echo ""
    echo "  WARNING: ${ENI_ID} still in status '${STATUS}' after waiting. Skipping."
  fi
done

echo ""
echo "Done. CloudFormation stack deletion should now complete."
