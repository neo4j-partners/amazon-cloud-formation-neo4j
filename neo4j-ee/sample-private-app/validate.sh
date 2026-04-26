#!/bin/bash
# validate.sh — Trigger the resilience test: stop a follower via SSM, verify it rejoins.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_FILE=$(ls -t "${SCRIPT_DIR}/../.deploy"/sample-private-app-*.json 2>/dev/null | head -1 || true)
if [ -z "${APP_FILE}" ]; then
  echo "ERROR: No sample-private-app deployment found. Run ./deploy-sample-private-app.sh first." >&2
  exit 1
fi

VALIDATE_URL=$(python3 -c "import json; d=json.load(open('${APP_FILE}')); print(d['validate_url'])")
REGION=$(python3 -c "import json; d=json.load(open('${APP_FILE}')); print(d['region'])")

eval "$(aws configure export-credentials --format env 2>/dev/null)"

curl --silent --max-time 310 --aws-sigv4 "aws:amz:${REGION}:lambda" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  -H "x-amz-security-token: ${AWS_SESSION_TOKEN}" \
  -H "Content-Type: application/json" \
  "${VALIDATE_URL}" | python3 -m json.tool
