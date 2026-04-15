#!/bin/bash
# create-ami.sh — Automate the EE Marketplace AMI build
#
# Launches an Amazon Linux 2023 instance, runs the build steps via UserData,
# waits for the instance to stop, creates an AMI with IMDSv2 enforced, and
# cleans up the build instance.
#
# Prerequisites:
#   - AWS CLI configured with the marketplace profile (neo4j-marketplace account)
#   - A key pair is NOT required — there is no SSH step
#
# Usage:
#   AWS_PROFILE=marketplace ./create-ami.sh
#
# The AMI is a base OS image only (SSH hardening + OS patches).
# Neo4j Enterprise is installed at deploy time via the CloudFormation UserData
# script, not baked into the AMI.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REGION="us-east-1"
AMI_NAME="neo4j-ee-base-$(date +%Y%m%d)"
INSTANCE_TYPE="t3.medium"

TAGS="ResourceType=instance,Tags=[{Key=Name,Value=neo4j-ee-ami-build},{Key=Purpose,Value=marketplace-ami-build}]"

# ---------------------------------------------------------------------------
# Preflight: verify we're in the correct AWS account
# ---------------------------------------------------------------------------
echo "=== Neo4j EE AMI Builder ==="
echo ""
echo "Verifying AWS identity..."

CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>&1) || {
  echo "ERROR: Failed to call sts get-caller-identity."
  echo "Make sure you are authenticated."
  exit 1
}

ACCOUNT_ID=$(echo "${CALLER_IDENTITY}" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
CALLER_ARN=$(echo "${CALLER_IDENTITY}" | grep -o '"Arn": "[^"]*"' | cut -d'"' -f4)

echo "  Account:  ${ACCOUNT_ID}"
echo "  Identity: ${CALLER_ARN}"
echo "  Region:   ${REGION} (overrides profile default)"
echo ""
echo "AMI name:      ${AMI_NAME}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Deregister any existing AMI with the same name
# ---------------------------------------------------------------------------
EXISTING_AMI=$(aws ec2 describe-images \
  --region "${REGION}" \
  --owners self \
  --filters "Name=name,Values=${AMI_NAME}" \
  --query "Images[0].ImageId" \
  --output text 2>/dev/null || true)

if [ -n "${EXISTING_AMI}" ] && [ "${EXISTING_AMI}" != "None" ]; then
  echo "Found existing AMI with name '${AMI_NAME}': ${EXISTING_AMI}"

  SNAP_IDS=$(aws ec2 describe-images \
    --region "${REGION}" \
    --image-ids "${EXISTING_AMI}" \
    --query "Images[0].BlockDeviceMappings[].Ebs.SnapshotId" \
    --output text 2>/dev/null || true)

  echo "Deregistering ${EXISTING_AMI}..."
  aws ec2 deregister-image \
    --region "${REGION}" \
    --image-id "${EXISTING_AMI}"

  for snap in ${SNAP_IDS}; do
    if [ -n "${snap}" ] && [ "${snap}" != "None" ]; then
      echo "Deleting snapshot ${snap}..."
      aws ec2 delete-snapshot --region "${REGION}" --snapshot-id "${snap}" 2>/dev/null || true
    fi
  done

  echo "Old AMI cleaned up."
else
  echo "No existing AMI named '${AMI_NAME}' found. Proceeding."
fi
echo ""

# ---------------------------------------------------------------------------
# Step 2: Resolve the latest Amazon Linux 2023 AMI
# ---------------------------------------------------------------------------
echo "Resolving latest Amazon Linux 2023 AMI..."
BASE_AMI=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region "${REGION}" \
  --query "Parameters[0].Value" \
  --output text)

if [ -z "${BASE_AMI}" ] || [ "${BASE_AMI}" == "None" ]; then
  echo "ERROR: Could not resolve Amazon Linux 2023 AMI. Check SSM parameter store access."
  exit 1
fi
echo "Base AMI: ${BASE_AMI}"

# ---------------------------------------------------------------------------
# Step 3: Create UserData that runs the build steps inline
# ---------------------------------------------------------------------------
echo "Preparing UserData..."

USERDATA=$(cat <<'BUILDSCRIPT'
#!/bin/bash
set -euo pipefail

echo "=== Neo4j EE Base AMI Build (via UserData) ==="

# --- Patch the OS ---
echo "Patching OS..."
dnf update -y

# --- SSH Hardening ---
sed -i 's/^#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i '/UseDNS/d' /etc/ssh/sshd_config
echo "UseDNS no" >> /etc/ssh/sshd_config
passwd -l root
shred -u /etc/ssh/*_key /etc/ssh/*_key.pub
rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys

# --- Clean up ---
dnf clean all
rm -rf /var/cache/dnf /tmp/* /var/tmp/*
shred -u /root/.bash_history 2>/dev/null || rm -f /root/.bash_history

# --- Signal completion and shut down ---
echo "=== Build complete. Shutting down. ==="
shutdown -h now
BUILDSCRIPT
)

USERDATA_B64=$(echo "${USERDATA}" | base64)

# ---------------------------------------------------------------------------
# Step 4: Launch the build instance
# ---------------------------------------------------------------------------
echo "Launching build instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --region "${REGION}" \
  --image-id "${BASE_AMI}" \
  --instance-type "${INSTANCE_TYPE}" \
  --user-data "${USERDATA_B64}" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications "${TAGS}" \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3,DeleteOnTermination=true}" \
  --query "Instances[0].InstanceId" \
  --output text)

if [ -z "${INSTANCE_ID}" ]; then
  echo "ERROR: Failed to launch instance."
  exit 1
fi
echo "Instance launched: ${INSTANCE_ID}"

# ---------------------------------------------------------------------------
# Step 5: Wait for build to finish (instance stops itself)
# ---------------------------------------------------------------------------
echo ""
echo "Waiting for instance to start..."
aws ec2 wait instance-running \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}"

echo "Instance running. Build in progress (typically 3-5 minutes)..."
echo "Waiting for instance to stop (build shuts down when done)..."
echo ""

aws ec2 wait instance-stopped \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}"

echo "Instance stopped. Build complete."

# ---------------------------------------------------------------------------
# Step 6: Create AMI from the stopped instance
# ---------------------------------------------------------------------------
echo "Creating AMI: ${AMI_NAME}..."
IMAGE_ID=$(aws ec2 create-image \
  --region "${REGION}" \
  --instance-id "${INSTANCE_ID}" \
  --name "${AMI_NAME}" \
  --description "Neo4j EE base image on Amazon Linux 2023 (Neo4j installed at deploy time)" \
  --query "ImageId" \
  --output text)

echo "AMI creation initiated: ${IMAGE_ID}"
echo "Waiting for AMI to become available..."

aws ec2 wait image-available \
  --region "${REGION}" \
  --image-ids "${IMAGE_ID}"

echo "AMI available: ${IMAGE_ID}"

# Enforce IMDSv2 on the AMI itself — required by AWS Marketplace policy.
# create-image does not accept --imds-support, so we set it post-creation.
echo "Enforcing IMDSv2 on AMI..."
aws ec2 modify-image-attribute \
  --region "${REGION}" \
  --image-id "${IMAGE_ID}" \
  --imds-support v2.0

# ---------------------------------------------------------------------------
# Step 7: Tag the AMI
# ---------------------------------------------------------------------------
echo "Tagging AMI..."
aws ec2 create-tags \
  --region "${REGION}" \
  --resources "${IMAGE_ID}" \
  --tags \
    Key=Name,Value="${AMI_NAME}" \
    Key=Neo4jEdition,Value="enterprise-base" \
    Key=BaseOS,Value="Amazon Linux 2023" \
    Key=IMDSv2,Value="v2.0-required" \
    Key=Purpose,Value="marketplace-ami"

# ---------------------------------------------------------------------------
# Step 8: Save AMI ID for downstream scripts
# ---------------------------------------------------------------------------
AMI_ID_FILE="$(dirname "$0")/ami-id.txt"
echo "${IMAGE_ID}" > "${AMI_ID_FILE}"
echo "AMI ID written to ${AMI_ID_FILE}"

# ---------------------------------------------------------------------------
# Step 9: Terminate the build instance
# ---------------------------------------------------------------------------
echo "Terminating build instance ${INSTANCE_ID}..."
aws ec2 terminate-instances \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}" > /dev/null

echo ""
echo "============================================="
echo "  AMI Build Complete"
echo "============================================="
echo ""
echo "  AMI ID:        ${IMAGE_ID}"
echo "  AMI Name:      ${AMI_NAME}"
echo "  Region:        ${REGION}"
echo ""
echo "Next steps:"
echo "  1. Test the AMI:"
echo "       AWS_PROFILE=marketplace ./marketplace/test-ami.sh"
echo ""
echo "  2. Run Marketplace AMI scan:"
echo "       Marketplace Portal > Products > Server > Request changes"
echo "       > Update versions > Test 'Add version'"
echo ""
echo "  3. Update the CFT ImageId parameter default with the product code"
echo "       once the Marketplace listing is published."
echo "============================================="
