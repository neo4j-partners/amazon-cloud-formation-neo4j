#!/bin/bash
# deploy-sample-private-app.sh — Deploy the Neo4j CDK demo app against an existing EE stack.
#
# Usage:
#   ./deploy-sample-private-app.sh [stack-name]
#
# If stack-name is omitted, uses the most recently modified file in .deploy/.
# Reads /neo4j-ee/<stack-name>/ SSM parameters written by the EE CloudFormation
# stack, passes them to CDK as context values, then writes the Function URL
# to SSM and .deploy/.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${EE_DIR}/.deploy"
CDK_DIR="${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Helper: read a value from a "Key = Value" file
# ---------------------------------------------------------------------------
read_field() {
  local file="$1"
  local key="$2"
  grep "^${key}" "$file" | sed 's/^[^=]*= *//' | tr -d '\r'
}

# ---------------------------------------------------------------------------
# Helper: require an SSM parameter
# ---------------------------------------------------------------------------
require_ssm() {
  local region="$1"
  local name="$2"
  local value
  value=$(aws ssm get-parameter \
    --region "${region}" \
    --name "${name}" \
    --query "Parameter.Value" \
    --output text 2>/dev/null || true)
  if [ -z "${value}" ]; then
    echo "ERROR: SSM parameter ${name} not found." >&2
    echo "Is the EE stack fully deployed and in Private mode?" >&2
    exit 1
  fi
  echo "${value}"
}

# ---------------------------------------------------------------------------
# Resolve the EE outputs file
# ---------------------------------------------------------------------------
if [ $# -ge 1 ]; then
  OUTPUTS_FILE="${DEPLOY_DIR}/$1.txt"
elif [ -d "${DEPLOY_DIR}" ]; then
  OUTPUTS_FILE=$(ls -t "${DEPLOY_DIR}"/*.txt 2>/dev/null | head -1 || true)
else
  OUTPUTS_FILE=""
fi

if [ -z "${OUTPUTS_FILE}" ] || [ ! -f "${OUTPUTS_FILE}" ]; then
  echo "ERROR: No EE deployment found." >&2
  echo "Run ./deploy.sh first, then ./deploy-sample-private-app.sh [stack-name]." >&2
  exit 1
fi

NEO4J_STACK=$(read_field "${OUTPUTS_FILE}" "StackName")
REGION=$(read_field "${OUTPUTS_FILE}" "Region")
DEPLOYMENT_MODE=$(read_field "${OUTPUTS_FILE}" "DeploymentMode")

if [ -z "${NEO4J_STACK}" ] || [ -z "${REGION}" ]; then
  echo "ERROR: Could not read StackName or Region from ${OUTPUTS_FILE}." >&2
  exit 1
fi

if [ "${DEPLOYMENT_MODE}" != "Private" ]; then
  echo "ERROR: CDK demo requires DeploymentMode=Private (got '${DEPLOYMENT_MODE}')." >&2
  exit 1
fi

SSM_PREFIX="/neo4j-ee/${NEO4J_STACK}"
CDK_STACK_NAME="neo4j-cdk-${NEO4J_STACK}"

echo "=== Neo4j CDK Demo Deploy ==="
echo ""
echo "  EE Stack:       ${NEO4J_STACK}"
echo "  CDK Stack:      ${CDK_STACK_NAME}"
echo "  Region:         ${REGION}"
echo "  SSM Prefix:     ${SSM_PREFIX}"
echo ""

# ---------------------------------------------------------------------------
# Resolve all context values from SSM before calling CDK
# ---------------------------------------------------------------------------
echo "Reading SSM parameters from EE stack..."
VPC_ID=$(require_ssm "${REGION}" "${SSM_PREFIX}/vpc-id")
NLB_DNS=$(require_ssm "${REGION}" "${SSM_PREFIX}/nlb-dns")
EXTERNAL_SG_ID=$(require_ssm "${REGION}" "${SSM_PREFIX}/external-sg-id")
PASSWORD_SECRET_ARN=$(require_ssm "${REGION}" "${SSM_PREFIX}/password-secret-arn")

echo "  vpc-id:              ${VPC_ID}"
echo "  nlb-dns:             ${NLB_DNS}"
echo "  external-sg-id:      ${EXTERNAL_SG_ID}"
echo "  password-secret-arn: ${PASSWORD_SECRET_ARN}"
echo ""

# ---------------------------------------------------------------------------
# Install CDK dependencies
# ---------------------------------------------------------------------------
echo "Installing CDK dependencies..."
cd "${CDK_DIR}"
python3 -m venv .venv 2>/dev/null || true
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -r requirements.txt

# Bundle Lambda dependencies cleanly: clear stale files, then install
find lambda/ -mindepth 1 -not -name 'handler.py' -not -name 'requirements.txt' -delete 2>/dev/null || true
pip install -q -r lambda/requirements.txt -t lambda/

# ---------------------------------------------------------------------------
# CDK bootstrap (idempotent)
# ---------------------------------------------------------------------------
CDK_DEFAULT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export CDK_DEFAULT_ACCOUNT
export CDK_DEFAULT_REGION="${REGION}"

echo "Bootstrapping CDK environment (idempotent)..."
cdk bootstrap "aws://${CDK_DEFAULT_ACCOUNT}/${REGION}" --quiet 2>/dev/null || true

# ---------------------------------------------------------------------------
# CDK deploy — context values replace SSM lookups inside the stack
# ---------------------------------------------------------------------------
echo "Deploying CDK stack ${CDK_STACK_NAME}..."
OUTPUTS_JSON="/tmp/cdk-outputs-$$.json"
cdk deploy \
  -c "cdkStackName=${CDK_STACK_NAME}" \
  -c "neo4jStack=${NEO4J_STACK}" \
  -c "vpcId=${VPC_ID}" \
  -c "externalSgId=${EXTERNAL_SG_ID}" \
  -c "passwordSecretArn=${PASSWORD_SECRET_ARN}" \
  --require-approval never \
  --outputs-file "${OUTPUTS_JSON}"

read -r FUNCTION_URL FUNCTION_ARN < <(python3 -c "
import json
data = json.load(open('${OUTPUTS_JSON}'))
s = list(data.keys())[0]
print(data[s]['FunctionUrl'], data[s]['FunctionArn'])
")
rm -f "${OUTPUTS_JSON}"

echo ""
echo "  Function URL: ${FUNCTION_URL}"
echo "  Function ARN: ${FUNCTION_ARN}"

# ---------------------------------------------------------------------------
# Write Function URL to SSM
# ---------------------------------------------------------------------------
CDK_SSM_PARAM="/neo4j-cdk/${CDK_STACK_NAME}/function-url"
echo ""
echo "Writing Function URL to SSM ${CDK_SSM_PARAM}..."
aws ssm put-parameter \
  --region "${REGION}" \
  --name "${CDK_SSM_PARAM}" \
  --type String \
  --value "${FUNCTION_URL}" \
  --overwrite > /dev/null

# ---------------------------------------------------------------------------
# Write local convenience file
# ---------------------------------------------------------------------------
mkdir -p "${DEPLOY_DIR}"
CDK_LOCAL_FILE="${DEPLOY_DIR}/cdk-${CDK_STACK_NAME}.json"
cat > "${CDK_LOCAL_FILE}" <<JSONEOF
{
  "stack_name": "${CDK_STACK_NAME}",
  "neo4j_stack": "${NEO4J_STACK}",
  "region": "${REGION}",
  "function_url": "${FUNCTION_URL}",
  "function_arn": "${FUNCTION_ARN}"
}
JSONEOF
echo "Wrote ${CDK_LOCAL_FILE}"

# ---------------------------------------------------------------------------
# Write invoke.sh
# ---------------------------------------------------------------------------
INVOKE_SCRIPT="${EE_DIR}/invoke.sh"
cat > "${INVOKE_SCRIPT}" <<'INVOKE_EOF'
#!/bin/bash
# invoke.sh — Call the Neo4j demo Lambda via its IAM-authenticated Function URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CDK_FILE=$(ls -t "${SCRIPT_DIR}/.deploy"/cdk-*.json 2>/dev/null | head -1 || true)
if [ -z "${CDK_FILE}" ]; then
  echo "ERROR: No CDK deployment found. Run ./sample-private-app/deploy-sample-private-app.sh first." >&2
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
INVOKE_EOF
chmod +x "${INVOKE_SCRIPT}"
echo "Wrote ${INVOKE_SCRIPT}"

deactivate 2>/dev/null || true

echo ""
echo "============================================="
echo "  CDK deploy complete."
echo "  To invoke:    ./invoke.sh           (from neo4j-ee/)"
echo "  To tear down: ./teardown-cdk.sh    (from neo4j-ee/)"
echo "============================================="
