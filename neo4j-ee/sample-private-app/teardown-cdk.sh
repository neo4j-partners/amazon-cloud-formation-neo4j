#!/bin/bash
# teardown-cdk.sh — Delete the Neo4j CDK demo stack and clean up resources.
#
# Usage:
#   ./teardown-cdk.sh [cdk-stack-name]
#
# If cdk-stack-name is omitted, uses the most recently modified cdk-*.json
# file in the parent neo4j-ee/.deploy/ directory.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/.deploy"

# ---------------------------------------------------------------------------
# Resolve the CDK outputs file
# ---------------------------------------------------------------------------
if [ $# -ge 1 ]; then
  CDK_FILE="${DEPLOY_DIR}/cdk-$1.json"
else
  CDK_FILE=$(ls -t "${DEPLOY_DIR}"/cdk-*.json 2>/dev/null | head -1 || true)
fi

if [ -z "${CDK_FILE}" ] || [ ! -f "${CDK_FILE}" ]; then
  echo "ERROR: No CDK deployment found." >&2
  echo "Usage: $0 [cdk-stack-name]" >&2
  exit 1
fi

STACK_NAME=$(python3 -c "import json; d=json.load(open('${CDK_FILE}')); print(d['stack_name'])")
REGION=$(python3 -c "import json; d=json.load(open('${CDK_FILE}')); print(d['region'])")

echo "=== Neo4j CDK Stack Teardown ==="
echo ""
echo "  CDK Stack: ${STACK_NAME}"
echo "  Region:    ${REGION}"
echo ""

# ---------------------------------------------------------------------------
# Delete the CDK stack via CloudFormation directly — avoids re-synthesizing
# the CDK app with real context values just to call delete-stack.
# ---------------------------------------------------------------------------
echo "Deleting CloudFormation stack ${STACK_NAME}..."
aws cloudformation delete-stack \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}"

echo "Waiting for stack deletion to complete..."
aws cloudformation wait stack-delete-complete \
  --stack-name "${STACK_NAME}" \
  --region "${REGION}"

echo "Stack deleted."

# ---------------------------------------------------------------------------
# Delete SSM parameter written by deploy-sample-private-app.sh
# ---------------------------------------------------------------------------
CDK_SSM_PARAM="/neo4j-cdk/${STACK_NAME}/function-url"
echo ""
echo "Deleting SSM parameter ${CDK_SSM_PARAM}..."
aws ssm delete-parameter \
  --region "${REGION}" \
  --name "${CDK_SSM_PARAM}" 2>/dev/null || true
echo "SSM parameter deleted."

# ---------------------------------------------------------------------------
# Clean up local files
# ---------------------------------------------------------------------------
echo ""
echo "Removing ${CDK_FILE}..."
rm -f "${CDK_FILE}"
rm -f "${SCRIPT_DIR}/invoke.sh"

echo ""
echo "============================================="
echo "  CDK teardown complete."
echo "============================================="
