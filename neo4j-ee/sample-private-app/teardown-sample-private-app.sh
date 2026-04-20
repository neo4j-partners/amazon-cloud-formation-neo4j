#!/bin/bash
# teardown-sample-private-app.sh — Delete the Neo4j sample private app stack and clean up.
#
# Usage:
#   ./teardown-sample-private-app.sh [ee-stack-name]
#
# If ee-stack-name is omitted, uses the most recently modified
# sample-private-app-*.json file in the parent neo4j-ee/.deploy/ directory.
#
# IMPORTANT: Always run this BEFORE tearing down the parent EE stack.
# This stack owns ingress rules on the EE security groups; deleting the
# EE stack first will leave those rules orphaned and the EE delete may fail.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/.deploy"

# ---------------------------------------------------------------------------
# Resolve the app outputs file
# ---------------------------------------------------------------------------
if [ $# -ge 1 ]; then
  APP_FILE="${DEPLOY_DIR}/sample-private-app-${1}.json"
else
  APP_FILE=$(ls -t "${DEPLOY_DIR}"/sample-private-app-*.json 2>/dev/null | head -1 || true)
fi

if [ -z "${APP_FILE}" ] || [ ! -f "${APP_FILE}" ]; then
  echo "ERROR: No sample-private-app deployment found." >&2
  echo "Usage: $0 [ee-stack-name]" >&2
  exit 1
fi

STACK_NAME=$(python3 -c "import json; d=json.load(open('${APP_FILE}')); print(d['stack_name'])")
REGION=$(python3 -c "import json; d=json.load(open('${APP_FILE}')); print(d['region'])")

echo "=== Neo4j Sample Private App Teardown ==="
echo ""
echo "  App Stack: ${STACK_NAME}"
echo "  Region:    ${REGION}"
echo ""

# ---------------------------------------------------------------------------
# Delete the CloudFormation stack
# ---------------------------------------------------------------------------
echo "Deleting CloudFormation stack ${STACK_NAME}..."
aws cloudformation delete-stack \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}"

echo "Waiting for stack deletion to complete..."
echo "(If this stalls, Lambda VPC ENIs may still be detaching — run ./force-delete-lambda-enis.sh in another terminal to unblock.)"
aws cloudformation wait stack-delete-complete \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}"
echo "Stack deleted."

# ---------------------------------------------------------------------------
# Delete SSM parameter written by deploy-sample-private-app.sh
# ---------------------------------------------------------------------------
APP_SSM_PARAM="/neo4j-sample-private-app/${STACK_NAME}/function-url"
echo ""
echo "Deleting SSM parameter ${APP_SSM_PARAM}..."
aws ssm delete-parameter \
  --region "${REGION}" \
  --name "${APP_SSM_PARAM}" 2>/dev/null || true
echo "SSM parameter deleted."

# ---------------------------------------------------------------------------
# Clean up the Lambda zip from S3 (all versions of the key)
# ---------------------------------------------------------------------------
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="neo4j-sample-private-app-deploy-${ACCOUNT_ID}-${REGION}"
LAMBDA_KEY="${STACK_NAME}/lambda.zip"

if aws s3api head-bucket --bucket "${DEPLOY_BUCKET}" 2>/dev/null; then
  echo ""
  echo "Deleting s3://${DEPLOY_BUCKET}/${LAMBDA_KEY} (all versions)..."
  DELETE_PAYLOAD=$(aws s3api list-object-versions \
    --bucket "${DEPLOY_BUCKET}" \
    --prefix "${LAMBDA_KEY}" \
    --query '{Objects: [Versions[*].{Key:Key,VersionId:VersionId},DeleteMarkers[*].{Key:Key,VersionId:VersionId}][]}' \
    --output json 2>/dev/null || echo '{"Objects":[]}')
  OBJECT_COUNT=$(echo "${DELETE_PAYLOAD}" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('Objects',[])))")
  if [ "${OBJECT_COUNT}" -gt 0 ]; then
    aws s3api delete-objects \
      --bucket "${DEPLOY_BUCKET}" \
      --delete "${DELETE_PAYLOAD}" > /dev/null
    echo "  Deleted ${OBJECT_COUNT} version(s)."
  else
    echo "  No versions found."
  fi
fi

# ---------------------------------------------------------------------------
# Clean up local files
# ---------------------------------------------------------------------------
echo ""
echo "Removing ${APP_FILE}..."
rm -f "${APP_FILE}"
rm -f "${SCRIPT_DIR}/invoke.sh"

echo ""
echo "============================================="
echo "  Sample private app teardown complete."
echo "============================================="
