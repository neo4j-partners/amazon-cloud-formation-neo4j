#!/bin/bash
# deploy-sample-private-app.sh — Deploy the Neo4j sample private Lambda app against
# an existing EE stack, using plain CloudFormation (no CDK).
#
# Usage:
#   ./deploy-sample-private-app.sh [stack-name] [--suffix <suffix>] [--enable-resilience] [--insecure-skip-verify]
#
# If stack-name is omitted, uses the most recently modified file in .deploy/.
# --suffix appends a string to the app stack name, allowing parallel deployments
# against the same EE stack (e.g. while a previous app stack is being torn down).
# --enable-resilience deploys the test-only Lambda that can stop/start Neo4j via SSM.
# --insecure-skip-verify uses neo4j+ssc for local self-signed certificate testing.
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
  grep "^${key}" "$file" 2>/dev/null | sed 's/^[^=]*= *//' | tr -d '\r' || true
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
# Parse arguments: optional positional stack-name and optional --suffix
# ---------------------------------------------------------------------------
SUFFIX=""
ENABLE_RESILIENCE="false"
BOLT_SCHEME="neo4j+s"
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --suffix)
      SUFFIX="-${2:?--suffix requires a value}"
      shift 2
      ;;
    --enable-resilience)
      ENABLE_RESILIENCE="true"
      shift
      ;;
    --insecure-skip-verify)
      BOLT_SCHEME="neo4j+ssc"
      shift
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}"

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
NUMBER_OF_SERVERS=$(read_field "${OUTPUTS_FILE}" "NumberOfServers")
SELF_SIGNED_CERTIFICATE=$(read_field "${OUTPUTS_FILE}" "SelfSignedCertificate")

if [ -z "${NEO4J_STACK}" ] || [ -z "${REGION}" ]; then
  echo "ERROR: Could not read StackName or Region from ${OUTPUTS_FILE}." >&2
  exit 1
fi

if [ "${DEPLOYMENT_MODE}" != "Private" ] && [ "${DEPLOYMENT_MODE}" != "ExistingVpc" ]; then
  echo "ERROR: Sample private app requires DeploymentMode=Private or ExistingVpc (got '${DEPLOYMENT_MODE}')." >&2
  exit 1
fi

if [ "${SELF_SIGNED_CERTIFICATE}" = "true" ] && [ "${BOLT_SCHEME}" = "neo4j+s" ]; then
  BOLT_SCHEME="neo4j+ssc"
fi

SSM_PREFIX="/neo4j-ee/${NEO4J_STACK}"
APP_STACK_NAME="neo4j-sample-private-app-${NEO4J_STACK}${SUFFIX}"

NEO4J_STACK_ID=$(aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${NEO4J_STACK}" \
  --query "Stacks[0].StackId" \
  --output text)
if [ -z "${NEO4J_STACK_ID}" ] || [ "${NEO4J_STACK_ID}" = "None" ]; then
  echo "ERROR: Could not resolve stack ID for ${NEO4J_STACK}." >&2
  exit 1
fi

echo "=== Neo4j Sample Private App Deploy ==="
echo ""
echo "  EE Stack:       ${NEO4J_STACK}"
echo "  App Stack:      ${APP_STACK_NAME}"
echo "  Region:         ${REGION}"
echo "  SSM Prefix:     ${SSM_PREFIX}"
echo "  Resilience:     ${ENABLE_RESILIENCE}"
echo "  Bolt Scheme:    ${BOLT_SCHEME}"
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
SUBNET_IDS="${PRIVATE_SUBNET_1_ID}"
PRIVATE_SUBNET_2_ID=""

if [ "${NUMBER_OF_SERVERS:-1}" != "1" ]; then
  PRIVATE_SUBNET_2_ID=$(require_ssm "${REGION}" "${SSM_PREFIX}/private-subnet-2-id")
  SUBNET_IDS="${PRIVATE_SUBNET_1_ID},${PRIVATE_SUBNET_2_ID}"
fi

echo "  vpc-id:              ${VPC_ID}"
echo "  external-sg-id:      ${EXTERNAL_SG_ID}"
echo "  password-secret-arn: ${PASSWORD_SECRET_ARN}"
echo "  vpc-endpoint-sg-id:  ${VPC_ENDPOINT_SG_ID}"
echo "  private-subnet-1-id: ${PRIVATE_SUBNET_1_ID}"
if [ -n "${PRIVATE_SUBNET_2_ID}" ]; then
  echo "  private-subnet-2-id: ${PRIVATE_SUBNET_2_ID}"
else
  echo "  private-subnet-2-id: not present for single-server EE stack"
fi
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
    "SubnetIds=${SUBNET_IDS}" \
    "ExternalSgId=${EXTERNAL_SG_ID}" \
    "VpcEndpointSgId=${VPC_ENDPOINT_SG_ID}" \
    "PasswordSecretArn=${PASSWORD_SECRET_ARN}" \
    "Neo4jStackName=${NEO4J_STACK}" \
    "Neo4jStackId=${NEO4J_STACK_ID}" \
    "LambdaS3Bucket=${DEPLOY_BUCKET}" \
    "LambdaS3Key=${LAMBDA_KEY}" \
    "LambdaS3ObjectVersion=${LAMBDA_VERSION_ID}" \
    "EnableResilienceTestFunction=${ENABLE_RESILIENCE}" \
    "BoltScheme=${BOLT_SCHEME}"

# ---------------------------------------------------------------------------
# Read stack outputs
# ---------------------------------------------------------------------------
OUTPUTS_JSON=$(aws cloudformation describe-stacks \
  --region "${REGION}" \
  --stack-name "${APP_STACK_NAME}" \
  --query 'Stacks[0].Outputs' \
  --output json)

FUNCTION_URL=$(echo "${OUTPUTS_JSON}" | python3 -c "
import json, sys
outs = {o['OutputKey']: o['OutputValue'] for o in json.load(sys.stdin)}
print(outs['FunctionUrl'])")
FUNCTION_ARN=$(echo "${OUTPUTS_JSON}" | python3 -c "
import json, sys
outs = {o['OutputKey']: o['OutputValue'] for o in json.load(sys.stdin)}
print(outs['FunctionArn'])")
VALIDATE_URL=$(echo "${OUTPUTS_JSON}" | python3 -c "
import json, sys
outs = {o['OutputKey']: o['OutputValue'] for o in json.load(sys.stdin)}
print(outs.get('ResilienceFunctionUrl', ''))")
VALIDATE_ARN=$(echo "${OUTPUTS_JSON}" | python3 -c "
import json, sys
outs = {o['OutputKey']: o['OutputValue'] for o in json.load(sys.stdin)}
print(outs.get('ResilienceFunctionArn', ''))")

echo ""
echo "  Function URL:  ${FUNCTION_URL}"
echo "  Function ARN:  ${FUNCTION_ARN}"
if [ "${ENABLE_RESILIENCE}" = "true" ]; then
  echo "  Validate URL:  ${VALIDATE_URL}"
  echo "  Validate ARN:  ${VALIDATE_ARN}"
else
  echo "  Validate URL:  disabled (rerun with --enable-resilience)"
fi

# ---------------------------------------------------------------------------
# Write local convenience file (invoke.sh reads the newest match)
# ---------------------------------------------------------------------------
mkdir -p "${DEPLOY_DIR}"
APP_LOCAL_FILE="${DEPLOY_DIR}/sample-private-app-${NEO4J_STACK}${SUFFIX}.json"
cat > "${APP_LOCAL_FILE}" <<JSONEOF
{
  "stack_name": "${APP_STACK_NAME}",
  "neo4j_stack": "${NEO4J_STACK}",
  "region": "${REGION}",
  "function_url": "${FUNCTION_URL}",
  "function_arn": "${FUNCTION_ARN}",
  "validate_url": "${VALIDATE_URL}",
  "validate_arn": "${VALIDATE_ARN}",
  "bolt_scheme": "${BOLT_SCHEME}"
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

BODY_FILE=$(mktemp)
STATUS=$(curl --silent --show-error --output "${BODY_FILE}" --write-out "%{http_code}" \
  --aws-sigv4 "aws:amz:${REGION}:lambda" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  -H "x-amz-security-token: ${AWS_SESSION_TOKEN:-}" \
  -H "Content-Type: application/json" \
  "${FUNCTION_URL}")

if [ "${STATUS}" -lt 200 ] || [ "${STATUS}" -ge 300 ]; then
  echo "ERROR: Function URL returned HTTP ${STATUS}" >&2
  cat "${BODY_FILE}" >&2
  echo >&2
  rm -f "${BODY_FILE}"
  exit 1
fi

python3 -m json.tool <"${BODY_FILE}"
rm -f "${BODY_FILE}"
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
if [ -z "${VALIDATE_URL}" ]; then
  echo "ERROR: This sample app was deployed without --enable-resilience." >&2
  echo "Redeploy with ./deploy-sample-private-app.sh --enable-resilience to create the test-only stop/start Lambda." >&2
  exit 1
fi

eval "$(aws configure export-credentials --format env 2>/dev/null)"

BODY_FILE=$(mktemp)
STATUS=$(curl --silent --show-error --output "${BODY_FILE}" --write-out "%{http_code}" \
  --max-time 310 --aws-sigv4 "aws:amz:${REGION}:lambda" \
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
  -H "x-amz-security-token: ${AWS_SESSION_TOKEN:-}" \
  -H "Content-Type: application/json" \
  "${VALIDATE_URL}")

if [ "${STATUS}" -lt 200 ] || [ "${STATUS}" -ge 300 ]; then
  echo "ERROR: Function URL returned HTTP ${STATUS}" >&2
  cat "${BODY_FILE}" >&2
  echo >&2
  rm -f "${BODY_FILE}"
  exit 1
fi

python3 -m json.tool <"${BODY_FILE}"
rm -f "${BODY_FILE}"
VALIDATE_EOF
chmod +x "${VALIDATE_SCRIPT}"
echo "Wrote ${VALIDATE_SCRIPT}"

echo ""
echo "============================================="
echo "  Deploy complete."
echo "  To invoke:    ./invoke.sh"
if [ "${ENABLE_RESILIENCE}" = "true" ]; then
  echo "  To validate:  ./validate.sh  (stops a follower, waits for recovery; ~60-120s)"
else
  echo "  Validation Lambda disabled. Redeploy with --enable-resilience for stop/start testing."
fi
echo "  To tear down: ./teardown-sample-private-app.sh"
echo "  (Always tear down the sample app BEFORE the parent EE stack —"
echo "   this stack owns ingress rules on the EE security groups.)"
echo "============================================="
