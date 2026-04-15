#!/bin/bash
#
# Deploy the Neo4j Enterprise Edition CloudFormation stack for local testing.
#
# Usage:
#   ./deploy.sh [instance-family] [--region REGION] [--number-of-servers N] [--marketplace] [--alert-email EMAIL]
#
# Stack name is auto-generated as test-ee-<timestamp>.
# Password is randomly generated and saved to .deploy/<stack-name>.txt.
#
# Instance family (optional, default: t3):
#   t3  -> t3.medium   (burstable, cheaper for quick tests)
#   r8i -> r8i.xlarge  (memory optimized)
#
# Region (optional, default: random from supported list):
#   AMIs built in us-east-1 are automatically copied when deploying elsewhere.
#   In --marketplace mode no AMI copy is needed.
#
# Number of servers (optional, default: 3):
#   1  -> single instance
#   3  -> three-node cluster
#
# AMI source:
#   Default (local): reads marketplace/ami-id.txt (written by build.sh), creates
#     a temporary SSM parameter and passes it as ImageId. Use this before
#     submitting a new AMI to the Marketplace.
#   --marketplace: skips AMI resolution entirely; the template uses its default
#     SSM path (/aws/service/marketplace/...) pointing to the live listing.
#     Use this to validate what a real customer would receive.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-default}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# Parse arguments: [instance-family] [--region REGION] [--number-of-servers N] [--marketplace]
# ---------------------------------------------------------------------------
INSTANCE_FAMILY=""
REGION_OVERRIDE=""
NUMBER_OF_SERVERS=""
USE_MARKETPLACE=false
ALERT_EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGION_OVERRIDE="$2"
      shift 2
      ;;
    --number-of-servers)
      NUMBER_OF_SERVERS="$2"
      shift 2
      ;;
    --marketplace)
      USE_MARKETPLACE=true
      shift
      ;;
    --alert-email)
      ALERT_EMAIL="$2"
      shift 2
      ;;
    -*)
      echo "ERROR: Unknown option '$1'." >&2
      echo "Usage: $0 [instance-family] [--region REGION] [--number-of-servers N] [--marketplace] [--alert-email EMAIL]" >&2
      exit 1
      ;;
    *)
      if [ -z "${INSTANCE_FAMILY}" ]; then
        INSTANCE_FAMILY="$1"
      else
        echo "ERROR: Unexpected argument '$1'." >&2
        echo "Usage: $0 [instance-family] [--region REGION] [--number-of-servers N] [--marketplace] [--alert-email EMAIL]" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

INSTANCE_FAMILY="${INSTANCE_FAMILY:-t3}"
NUMBER_OF_SERVERS="${NUMBER_OF_SERVERS:-3}"

# ---------------------------------------------------------------------------
# Resolve instance type from the instance-family argument
# ---------------------------------------------------------------------------
case "${INSTANCE_FAMILY}" in
  t3)  INSTANCE_TYPE="t3.medium" ;;
  r8i) INSTANCE_TYPE="r8i.xlarge" ;;
  *)
    echo "ERROR: Unsupported instance family '${INSTANCE_FAMILY}'." >&2
    echo "Supported families: t3, r8i" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Validate number of servers
# ---------------------------------------------------------------------------
case "${NUMBER_OF_SERVERS}" in
  1|3) ;;
  *)
    echo "ERROR: --number-of-servers must be 1 or 3 (got '${NUMBER_OF_SERVERS}')." >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# Select region — explicit override or random from supported list
# ---------------------------------------------------------------------------
SOURCE_REGION="us-east-1"
SUPPORTED_REGIONS=(us-east-1 us-east-2 us-west-2 eu-west-1 eu-central-1 ap-southeast-1 ap-southeast-2)

if [ -n "${REGION_OVERRIDE}" ]; then
  REGION="${REGION_OVERRIDE}"
else
  REGION="${SUPPORTED_REGIONS[$((RANDOM % ${#SUPPORTED_REGIONS[@]}))]}"
fi

# ---------------------------------------------------------------------------
# Stack configuration
# ---------------------------------------------------------------------------
STACK_NAME="test-ee-$(date +%s)"
TEMPLATE_BODY="file://neo4j.template.yaml"
# Password must satisfy the template AllowedPattern (letters + numbers).
# Append a random digit to guarantee the pattern matches.
Password="$(openssl rand -base64 12)$(( RANDOM % 10 ))"

# ---------------------------------------------------------------------------
# AMI resolution (local mode only)
# ---------------------------------------------------------------------------
COPIED_AMI_ID=""
SSM_PARAM_PATH=""
AMI_SOURCE="marketplace"

if [ "${USE_MARKETPLACE}" = false ]; then
  AMI_SOURCE="local"
  AMI_ID_FILE="${SCRIPT_DIR}/marketplace/ami-id.txt"

  if [ ! -f "${AMI_ID_FILE}" ]; then
    echo "ERROR: ${AMI_ID_FILE} not found. Run marketplace/build.sh first," >&2
    echo "       or use --marketplace to deploy from the live Marketplace listing." >&2
    exit 1
  fi

  SOURCE_AMI_ID="$(cat "${AMI_ID_FILE}")"

  # Cross-region AMI copy
  cleanup_copied_ami() {
    if [ -n "${COPIED_AMI_ID}" ]; then
      echo ""
      echo "Cleaning up copied AMI ${COPIED_AMI_ID} in ${REGION}..."
      aws ec2 deregister-image --region "${REGION}" --image-id "${COPIED_AMI_ID}" 2>/dev/null || true
      aws ec2 describe-snapshots \
        --region "${REGION}" \
        --filters "Name=description,Values=*${COPIED_AMI_ID}*" \
        --query "Snapshots[].SnapshotId" \
        --output text 2>/dev/null | while read -r snap_id; do
          [ -n "${snap_id}" ] && aws ec2 delete-snapshot --region "${REGION}" --snapshot-id "${snap_id}" 2>/dev/null || true
        done
    fi
  }

  if [ "${REGION}" != "${SOURCE_REGION}" ]; then
    echo "Copying AMI ${SOURCE_AMI_ID} from ${SOURCE_REGION} to ${REGION}..."
    COPIED_AMI_ID=$(aws ec2 copy-image \
      --source-region "${SOURCE_REGION}" \
      --source-image-id "${SOURCE_AMI_ID}" \
      --region "${REGION}" \
      --name "neo4j-ee-copy-${STACK_NAME}" \
      --description "Copied from ${SOURCE_AMI_ID} in ${SOURCE_REGION} for ${STACK_NAME}" \
      --query "ImageId" \
      --output text)
    echo "Copied AMI: ${COPIED_AMI_ID} — waiting for it to become available..."

    trap cleanup_copied_ami EXIT

    aws ec2 wait image-available --region "${REGION}" --image-ids "${COPIED_AMI_ID}"
    echo "AMI available in ${REGION}."

    AMI_ID="${COPIED_AMI_ID}"
  else
    AMI_ID="${SOURCE_AMI_ID}"
  fi

  # Create SSM parameter for the AMI ID
  SSM_PARAM_PATH="/neo4j-ee/test/${STACK_NAME}/ami-id"
  echo "Creating SSM parameter ${SSM_PARAM_PATH} -> ${AMI_ID}..."
  aws ssm put-parameter \
    --region "$REGION" \
    --name "${SSM_PARAM_PATH}" \
    --type String \
    --value "${AMI_ID}" \
    --overwrite > /dev/null
fi

# ---------------------------------------------------------------------------
# Deployment summary banner
# ---------------------------------------------------------------------------
echo ""
echo "============================================="
echo "  Neo4j EE Deployment"
echo "============================================="
echo "  Stack:          ${STACK_NAME}"
echo "  Region:         ${REGION}"
echo "  Instance:       ${INSTANCE_TYPE} (family: ${INSTANCE_FAMILY})"
echo "  Servers:        ${NUMBER_OF_SERVERS}"
echo "  AMI source:     ${AMI_SOURCE}"
if [ "${USE_MARKETPLACE}" = false ]; then
  echo "  AMI:            ${AMI_ID}"
  if [ -n "${COPIED_AMI_ID}" ]; then
    echo "  AMI original:   ${SOURCE_AMI_ID} (copied from ${SOURCE_REGION})"
  fi
fi
if [ -n "${ALERT_EMAIL}" ]; then
  echo "  Alert email:    ${ALERT_EMAIL}"
fi
echo "============================================="
echo ""

# ---------------------------------------------------------------------------
# Create stack
# ---------------------------------------------------------------------------
PARAMS="ParameterKey=Password,ParameterValue=${Password}"
PARAMS="${PARAMS} ParameterKey=NumberOfServers,ParameterValue=${NUMBER_OF_SERVERS}"
PARAMS="${PARAMS} ParameterKey=InstanceType,ParameterValue=${INSTANCE_TYPE}"
if [ -n "${SSM_PARAM_PATH}" ]; then
  PARAMS="${PARAMS} ParameterKey=ImageId,ParameterValue=${SSM_PARAM_PATH}"
fi
if [ -n "${ALERT_EMAIL}" ]; then
  PARAMS="${PARAMS} ParameterKey=AlertEmail,ParameterValue=${ALERT_EMAIL}"
fi

echo "Creating stack ${STACK_NAME}..."
aws cloudformation create-stack \
  --capabilities CAPABILITY_IAM \
  --stack-name "$STACK_NAME" \
  --template-body "$TEMPLATE_BODY" \
  --region "$REGION" \
  --disable-rollback \
  --parameters $PARAMS

echo "Waiting for stack to complete (this takes a few minutes)..."
aws cloudformation wait stack-create-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

# Stack succeeded — disarm the AMI cleanup trap
trap - EXIT 2>/dev/null || true

# ---------------------------------------------------------------------------
# Write outputs to .deploy/<stack-name>.txt
# ---------------------------------------------------------------------------
mkdir -p "${SCRIPT_DIR}/.deploy"
OUTPUTS_FILE="${SCRIPT_DIR}/.deploy/${STACK_NAME}.txt"

echo "Stack created. Writing outputs to ${OUTPUTS_FILE}..."

# CloudFormation outputs
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output text | while read -r key value; do
    printf "%-20s = %s\n" "$key" "$value"
  done | tee "${OUTPUTS_FILE}"

# Deploy context (values not in CloudFormation outputs)
{
  printf "%-20s = %s\n" "StackName" "$STACK_NAME"
  printf "%-20s = %s\n" "Region" "$REGION"
  printf "%-20s = %s\n" "Password" "$Password"
  printf "%-20s = %s\n" "NumberOfServers" "$NUMBER_OF_SERVERS"
  printf "%-20s = %s\n" "InstanceType" "$INSTANCE_TYPE"
  printf "%-20s = %s\n" "Edition" "ee"
  printf "%-20s = %s\n" "AmiSource" "$AMI_SOURCE"
  if [ -n "${ALERT_EMAIL}" ]; then
    printf "%-20s = %s\n" "AlertEmail" "$ALERT_EMAIL"
  fi
  if [ -n "${SSM_PARAM_PATH}" ]; then
    printf "%-20s = %s\n" "SSMParamPath" "$SSM_PARAM_PATH"
    printf "%-20s = %s\n" "AmiId" "$AMI_ID"
  fi
  if [ -n "${COPIED_AMI_ID}" ]; then
    printf "%-20s = %s\n" "CopiedAmiId" "$COPIED_AMI_ID"
    printf "%-20s = %s\n" "SourceRegion" "$SOURCE_REGION"
  fi
} | tee -a "${OUTPUTS_FILE}"

echo ""
echo "Outputs saved to ${OUTPUTS_FILE}"
echo ""
echo "To test:      cd test_neo4j && uv run test-neo4j --edition ee --stack ${STACK_NAME}"
echo "To tear down: ./teardown.sh ${STACK_NAME}"
