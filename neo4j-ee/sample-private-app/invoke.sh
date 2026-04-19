#!/bin/bash
# invoke.sh — Call the Neo4j demo Lambda via its IAM-authenticated Function URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CDK_FILE=$(ls -t "${SCRIPT_DIR}/../.deploy"/cdk-*.json 2>/dev/null | head -1 || true)
if [ -z "${CDK_FILE}" ]; then
  echo "ERROR: No CDK deployment found. Run ./deploy-sample-private-app.sh first." >&2
  exit 1
fi

FUNCTION_URL=$(python3 -c "import json; d=json.load(open('${CDK_FILE}')); print(d['function_url'])")
REGION=$(python3 -c "import json; d=json.load(open('${CDK_FILE}')); print(d['region'])")

eval "$(aws configure export-credentials --format env 2>/dev/null)"

curl --silent --aws-sigv4 "aws:amz:${REGION}:lambda" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  -H "x-amz-security-token: ${AWS_SESSION_TOKEN}" \
  -H "Content-Type: application/json" \
  "${FUNCTION_URL}" | python3 -m json.tool
