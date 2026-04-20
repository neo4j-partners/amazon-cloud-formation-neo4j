#!/bin/bash
# deploy-sample-private-app.sh — Deploy the Neo4j sample private Lambda app against
# an existing EE stack, using plain CloudFormation (no CDK).
#
# Usage:
#   ./deploy-sample-private-app.sh [stack-name]
#
# If stack-name is omitted, uses the most recently modified file in .deploy/.
# Reads /neo4j-ee/<stack-name>/ SSM parameters written by the EE CloudFormation
# stack, packages the Lambda, uploads it, deploys the template, then writes the
# Function URL to SSM and .deploy/.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${EE_DIR}/.deploy"
TEMPLATE_FILE="${SCRIPT_DIR}/sample-private-app.template.yaml"

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
  OUTPUTS_FILE="${DEPLOY_DIR}/${1%.txt}.txt"
elif [ -d "${DEPLOY_DIR}" ]; then
  OUTPUTS_FILE=$(ls -t "${DEPLOY_DIR}"/*.txt 2>/dev/null | head -1 || true)
else
  OUTPUTS_FILE=""
fi

if [ -z "${OUTPUTS_FILE}" ] || [ ! -f "${OUTPUTS_FILE}" ]; then
  echo "ERROR: No EE deployment found." >&2
  echo "Run ../deploy.py first, then ./deploy-sample-private-app.sh [stack-name]." >&2
  exit 1
fi

NEO4J_STACK=$(read_field "${OUTPUTS_FILE}" "StackName")
REGION=$(read_field "${OUTPUTS_FILE}" "Region")
DEPLOYMENT_MODE=$(read_field "${OUTPUTS_FILE}" "DeploymentMode")
BOLT_TLS_ARN=$(read_field "${OUTPUTS_FILE}" "BoltTlsSecretArn")

if [ -z "${NEO4J_STACK}" ] || [ -z "${REGION}" ]; then
  echo "ERROR: Could not read StackName or Region from ${OUTPUTS_FILE}." >&2
  exit 1
fi

if [ "${DEPLOYMENT_MODE}" != "Private" ]; then
  echo "ERROR: Sample private app requires DeploymentMode=Private (got '${DEPLOYMENT_MODE}')." >&2
  exit 1
fi

SSM_PREFIX="/neo4j-ee/${NEO4J_STACK}"
APP_STACK_NAME="neo4j-sample-private-app-${NEO4J_STACK}"

echo "=== Neo4j Sample Private App Deploy ==="
echo ""
echo "  EE Stack:       ${NEO4J_STACK}"
echo "  App Stack:      ${APP_STACK_NAME}"
echo "  Region:         ${REGION}"
echo "  SSM Prefix:     ${SSM_PREFIX}"
echo ""

# ---------------------------------------------------------------------------
# Resolve context values from SSM
# ---------------------------------------------------------------------------
echo "Reading SSM parameters from EE stack..."
VPC_ID=$(require_ssm "${REGION}" "${SSM_PREFIX}/vpc-id")
EXTERNAL_SG_ID=$(require_ssm "${REGION}" "${SSM_PREFIX}/external-sg-id")
PASSWORD_SECRET_ARN=$(require_ssm "${REGION}" "${SSM_PREFIX}/password-secret-arn")
VPC_ENDPOINT_SG_ID=$(require_ssm "${REGION}" "${SSM_PREFIX}/vpc-endpoint-sg-id")
PRIVATE_SUBNET_1_ID=$(require_ssm "${REGION}" "${SSM_PREFIX}/private-subnet-1-id")
PRIVATE_SUBNET_2_ID=$(require_ssm "${REGION}" "${SSM_PREFIX}/private-subnet-2-id")

echo "  vpc-id:              ${VPC_ID}"
echo "  external-sg-id:      ${EXTERNAL_SG_ID}"
echo "  password-secret-arn: ${PASSWORD_SECRET_ARN}"
echo "  vpc-endpoint-sg-id:  ${VPC_ENDPOINT_SG_ID}"
echo "  private-subnet-1-id: ${PRIVATE_SUBNET_1_ID}"
echo "  private-subnet-2-id: ${PRIVATE_SUBNET_2_ID}"
echo "  bolt-tls:            ${BOLT_TLS_ARN:-disabled}"
echo ""

# ---------------------------------------------------------------------------
# Package the Lambda: clear stale files, pip install deps, zip
# ---------------------------------------------------------------------------
echo "Packaging Lambda..."
cd "${SCRIPT_DIR}"
find lambda/ -mindepth 1 -not -name 'handler.py' -not -name 'requirements.txt' -delete 2>/dev/null || true
pip3 install -q -r lambda/requirements.txt -t lambda/

LAMBDA_ZIP="${SCRIPT_DIR}/lambda.zip"
rm -f "${LAMBDA_ZIP}"
(cd lambda && zip -qr "${LAMBDA_ZIP}" .)
echo "  zip: ${LAMBDA_ZIP} ($(wc -c <"${LAMBDA_ZIP}") bytes)"

# ---------------------------------------------------------------------------
# Ensure the deploy bucket exists (repo-controlled name, no SCP collision)
# ---------------------------------------------------------------------------
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="neo4j-sample-private-app-deploy-${ACCOUNT_ID}-${REGION}"

if ! aws s3api head-bucket --bucket "${DEPLOY_BUCKET}" 2>/dev/null; then
  echo "Creating deploy bucket ${DEPLOY_BUCKET}..."
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "${DEPLOY_BUCKET}" --region "${REGION}" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "${DEPLOY_BUCKET}" \
      --region "${REGION}" \
      --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
  fi
  aws s3api put-bucket-versioning \
    --bucket "${DEPLOY_BUCKET}" \
    --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-public-access-block \
    --bucket "${DEPLOY_BUCKET}" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
else
  echo "Deploy bucket ${DEPLOY_BUCKET} already exists."
fi

LAMBDA_KEY="${APP_STACK_NAME}/lambda.zip"
echo "Uploading Lambda zip to s3://${DEPLOY_BUCKET}/${LAMBDA_KEY}..."
LAMBDA_VERSION_ID=$(aws s3api put-object \
  --bucket "${DEPLOY_BUCKET}" \
  --key "${LAMBDA_KEY}" \
  --body "${LAMBDA_ZIP}" \
  --query VersionId \
  --output text)
echo "  version: ${LAMBDA_VERSION_ID}"
rm -f "${LAMBDA_ZIP}"

# ---------------------------------------------------------------------------
# Deploy the CloudFormation stack
# ---------------------------------------------------------------------------
BOLT_TLS_ENABLED="false"
[ -n "${BOLT_TLS_ARN}" ] && BOLT_TLS_ENABLED="true"

echo "Deploying CloudFormation stack ${APP_STACK_NAME}..."
aws cloudformation deploy \
  --region "${REGION}" \
  --stack-name "${APP_STACK_NAME}" \
  --template-file "${TEMPLATE_FILE}" \
  --capabilities CAPABILITY_IAM \
  --tags \
    "Project=neo4j-sample-private-app" \
    "Neo4jStack=${NEO4J_STACK}" \
  --parameter-overrides \
    "SsmPrefix=${SSM_PREFIX}" \
    "VpcId=${VPC_ID}" \
    "SubnetIds=${PRIVATE_SUBNET_1_ID},${PRIVATE_SUBNET_2_ID}" \
    "ExternalSgId=${EXTERNAL_SG_ID}" \
    "VpcEndpointSgId=${VPC_ENDPOINT_SG_ID}" \
    "PasswordSecretArn=${PASSWORD_SECRET_ARN}" \
    "BoltTlsEnabled=${BOLT_TLS_ENABLED}" \
    "Neo4jStackName=${NEO4J_STACK}" \
    "LambdaS3Bucket=${DEPLOY_BUCKET}" \
    "LambdaS3Key=${LAMBDA_KEY}" \
    "LambdaS3ObjectVersion=${LAMBDA_VERSION_ID}"

# ---------------------------------------------------------------------------
# Read stack outputs
# ---------------------------------------------------------------------------
OUTPUTS_JSON=$(aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${APP_STACK_NAME}" \
  --query 'Stacks[0].Outputs' \
  --output json)

read -r FUNCTION_URL FUNCTION_ARN VALIDATE_URL VALIDATE_ARN < <(echo "${OUTPUTS_JSON}" | python3 -c "
import json, sys
outs = {o['OutputKey']: o['OutputValue'] for o in json.load(sys.stdin)}
print(outs['FunctionUrl'], outs['FunctionArn'], outs['ResilienceFunctionUrl'], outs['ResilienceFunctionArn'])")

echo ""
echo "  Function URL:  ${FUNCTION_URL}"
echo "  Function ARN:  ${FUNCTION_ARN}"
echo "  Validate URL:  ${VALIDATE_URL}"
echo "  Validate ARN:  ${VALIDATE_ARN}"

# ---------------------------------------------------------------------------
# Write local convenience file (invoke.sh reads the newest match)
# ---------------------------------------------------------------------------
mkdir -p "${DEPLOY_DIR}"
APP_LOCAL_FILE="${DEPLOY_DIR}/sample-private-app-${NEO4J_STACK}.json"
cat > "${APP_LOCAL_FILE}" <<JSONEOF
{
  "stack_name": "${APP_STACK_NAME}",
  "neo4j_stack": "${NEO4J_STACK}",
  "region": "${REGION}",
  "function_url": "${FUNCTION_URL}",
  "function_arn": "${FUNCTION_ARN}",
  "validate_url": "${VALIDATE_URL}",
  "validate_arn": "${VALIDATE_ARN}"
}
JSONEOF
echo "Wrote ${APP_LOCAL_FILE}"

# ---------------------------------------------------------------------------
# Write invoke.sh
# ---------------------------------------------------------------------------
INVOKE_SCRIPT="${SCRIPT_DIR}/invoke.sh"
cat > "${INVOKE_SCRIPT}" <<'INVOKE_EOF'
#!/bin/bash
# invoke.sh — Call the Neo4j sample private Lambda via its IAM-authenticated Function URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_FILE=$(ls -t "${SCRIPT_DIR}/../.deploy"/sample-private-app-*.json 2>/dev/null | head -1 || true)
if [ -z "${APP_FILE}" ]; then
  echo "ERROR: No sample-private-app deployment found. Run ./deploy-sample-private-app.sh first." >&2
  exit 1
fi

FUNCTION_URL=$(python3 -c "import json; d=json.load(open('${APP_FILE}')); print(d['function_url'])")
REGION=$(python3 -c "import json; d=json.load(open('${APP_FILE}')); print(d['region'])")

eval "$(aws configure export-credentials --format env 2>/dev/null)"

curl --silent --aws-sigv4 "aws:amz:${REGION}:lambda" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  -H "x-amz-security-token: ${AWS_SESSION_TOKEN}" \
  -H "Content-Type: application/json" \
  "${FUNCTION_URL}" | python3 -m json.tool
INVOKE_EOF
chmod +x "${INVOKE_SCRIPT}"
echo "Wrote ${INVOKE_SCRIPT}"

VALIDATE_SCRIPT="${SCRIPT_DIR}/validate.sh"
cat > "${VALIDATE_SCRIPT}" <<'VALIDATE_EOF'
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
VALIDATE_EOF
chmod +x "${VALIDATE_SCRIPT}"
echo "Wrote ${VALIDATE_SCRIPT}"

echo ""
echo "============================================="
echo "  Deploy complete."
echo "  To invoke:    ./invoke.sh"
echo "  To validate:  ./validate.sh  (stops a follower, waits for recovery; ~60-120s)"
echo "  To tear down: ./teardown-sample-private-app.sh"
echo "  (Always tear down the sample app BEFORE the parent EE stack —"
echo "   this stack owns ingress rules on the EE security groups.)"
echo "============================================="
