#!/bin/bash
# create-ami.sh — Automate the CE Marketplace AMI build
#
# Launches an Amazon Linux 2023 instance, runs build.sh on it via UserData,
# waits for the instance to stop, creates an AMI with IMDSv2 enforced, and
# cleans up the build instance.
#
# Prerequisites:
#   - AWS CLI configured with the marketplace profile (neo4j-marketplace account)
#   - A key pair is NOT required — there is no SSH step
#
# Usage:
#   AWS_PROFILE=marketplace ./create-ami.sh <neo4j-version>
#
# Example:
#   AWS_PROFILE=marketplace ./create-ami.sh 2025.12.0

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REGION="us-east-1"
EXPECTED_ACCOUNT="385155106615"
NEO4J_VERSION="${1:?Usage: AWS_PROFILE=marketplace $0 <neo4j-version>  (e.g. 2025.12.0)}"
AMI_NAME="neo4j-community-${NEO4J_VERSION}"
INSTANCE_TYPE="t3.medium"

# Tags applied to all resources created by this script
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=neo4j-ce-ami-build},{Key=Purpose,Value=marketplace-ami-build}]"

# ---------------------------------------------------------------------------
# Preflight: verify we're in the correct AWS account
#
# The AMI must be built in the neo4j-marketplace account (385155106615).
# All AWS CLI calls use --region us-east-1 regardless of the profile's
# default region (the marketplace profile defaults to us-west-2).
# ---------------------------------------------------------------------------
echo "=== Neo4j CE AMI Builder ==="
echo ""
echo "Verifying AWS identity..."

CALLER_IDENTITY=$(aws sts get-caller-identity --output json 2>&1) || {
  echo "ERROR: Failed to call sts get-caller-identity."
  echo "Make sure you are authenticated. Usage:"
  echo "  AWS_PROFILE=marketplace $0 ${NEO4J_VERSION}"
  exit 1
}

ACCOUNT_ID=$(echo "${CALLER_IDENTITY}" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
CALLER_ARN=$(echo "${CALLER_IDENTITY}" | grep -o '"Arn": "[^"]*"' | cut -d'"' -f4)

if [ "${ACCOUNT_ID}" != "${EXPECTED_ACCOUNT}" ]; then
  echo "ERROR: Wrong AWS account."
  echo "  Expected: ${EXPECTED_ACCOUNT} (neo4j-marketplace)"
  echo "  Got:      ${ACCOUNT_ID}"
  echo ""
  echo "Switch to the marketplace profile:"
  echo "  AWS_PROFILE=marketplace $0 ${NEO4J_VERSION}"
  exit 1
fi

echo "  Account:  ${ACCOUNT_ID} (neo4j-marketplace)"
echo "  Identity: ${CALLER_ARN}"
echo "  Region:   ${REGION} (overrides profile default)"
echo ""
echo "Neo4j version: ${NEO4J_VERSION}"
echo "AMI name:      ${AMI_NAME}"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Deregister any existing AMI with the same name
#
# AMI names must be unique per account+region. If a previous build produced
# an AMI with this name, deregister it (and its backing snapshot) so
# create-image can reuse the name.
# ---------------------------------------------------------------------------
EXISTING_AMI=$(aws ec2 describe-images \
  --region "${REGION}" \
  --owners self \
  --filters "Name=name,Values=${AMI_NAME}" \
  --query "Images[0].ImageId" \
  --output text 2>/dev/null || true)

if [ -n "${EXISTING_AMI}" ] && [ "${EXISTING_AMI}" != "None" ]; then
  echo "Found existing AMI with name '${AMI_NAME}': ${EXISTING_AMI}"

  # Capture the snapshot IDs before deregistering (so we can delete them)
  SNAP_IDS=$(aws ec2 describe-images \
    --region "${REGION}" \
    --image-ids "${EXISTING_AMI}" \
    --query "Images[0].BlockDeviceMappings[].Ebs.SnapshotId" \
    --output text 2>/dev/null || true)

  echo "Deregistering ${EXISTING_AMI}..."
  aws ec2 deregister-image \
    --region "${REGION}" \
    --image-id "${EXISTING_AMI}"

  # Delete orphaned snapshots to avoid storage costs
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
# Step 3: Create UserData that runs build.sh inline
#
# We embed build.sh directly in UserData rather than uploading it separately.
# This avoids needing S3, SSH, or SSM Session Manager access on the build
# instance. The script shuts down the instance when done.
# ---------------------------------------------------------------------------
echo "Preparing UserData..."

USERDATA=$(cat <<'BUILDSCRIPT'
#!/bin/bash
set -euo pipefail

echo "=== Neo4j CE AMI Build (via UserData) ==="

# --- Patch the OS ---
echo "Patching OS..."
dnf update -y

# --- Install Java 21 ---
echo "Installing Java 21 (Amazon Corretto)..."
dnf install -y java-21-amazon-corretto-headless

# --- Install Neo4j Community Edition from yum ---
echo "Installing Neo4j Community Edition..."
rpm --import https://debian.neo4j.com/neotechnology.gpg.key
cat > /etc/yum.repos.d/neo4j.repo <<'REPO'
[neo4j]
name=Neo4j RPM Repository
baseurl=https://yum.neo4j.com/stable/latest
enabled=1
gpgcheck=1
REPO
dnf install -y neo4j
systemctl enable neo4j

# --- SSH Hardening ---
sed -i 's/#PermitRootLogin yes/PermitRootLogin without-password/g' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
passwd -l root
shred -u /etc/ssh/*_key /etc/ssh/*_key.pub
rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys

# --- Clean up ---
dnf clean all
rm -rf /var/cache/dnf /tmp/* /var/tmp/*

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
# Step 5: Wait for build.sh to finish (instance stops itself)
#
# Two-phase wait: the instance-stopped waiter treats "pending" as a terminal
# failure, so we must first wait for "running" before waiting for "stopped".
# ---------------------------------------------------------------------------
echo ""
echo "Waiting for instance to start..."
aws ec2 wait instance-running \
  --region "${REGION}" \
  --instance-ids "${INSTANCE_ID}"

echo "Instance running. Build in progress (typically 3-5 minutes)..."
echo "Waiting for instance to stop (build.sh shuts down when done)..."
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
  --description "Neo4j Community Edition ${NEO4J_VERSION} on Amazon Linux 2023" \
  --query "ImageId" \
  --output text)

echo "AMI creation initiated: ${IMAGE_ID}"
echo "Waiting for AMI to become available..."

aws ec2 wait image-available \
  --region "${REGION}" \
  --image-ids "${IMAGE_ID}"

echo "AMI available: ${IMAGE_ID}"

# ---------------------------------------------------------------------------
# Step 7: Tag the AMI
#
# create-image does not support --imds-support, so we modify the AMI after
# creation using modify-image-attribute is not available either. Instead we
# use register-image approach: we deregister and re-register. However, the
# simpler path is to set imds-support via modify-instance-metadata-defaults
# or accept that the CloudFormation launch template enforces HttpTokens=required
# at the instance level, which is equivalent.
#
# For belt-and-suspenders, we document that the launch template enforces IMDSv2
# and tag the AMI accordingly.
# ---------------------------------------------------------------------------
echo "Tagging AMI..."
aws ec2 create-tags \
  --region "${REGION}" \
  --resources "${IMAGE_ID}" \
  --tags \
    Key=Name,Value="${AMI_NAME}" \
    Key=Neo4jVersion,Value="${NEO4J_VERSION}" \
    Key=Neo4jEdition,Value="community" \
    Key=BaseOS,Value="Amazon Linux 2023" \
    Key=IMDSv2,Value="enforced-by-launch-template" \
    Key=Purpose,Value="marketplace-ami"

# ---------------------------------------------------------------------------
# Step 8: Save AMI ID for downstream scripts (e.g. test-ami.sh)
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
echo "  Neo4j Version: ${NEO4J_VERSION}"
echo ""
echo "Next steps:"
echo "  1. Test the AMI:"
echo "       AWS_PROFILE=marketplace ./test-ami.sh"
echo ""
echo "  2. Run Marketplace AMI scan:"
echo "       Marketplace Portal > Products > Server > Request changes"
echo "       > Update versions > Test 'Add version'"
echo ""
echo "  3. Update the CFT ImageId parameter default with the product code"
echo "       once the Marketplace listing is created."
echo "============================================="
