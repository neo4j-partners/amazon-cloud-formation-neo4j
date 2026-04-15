#!/bin/bash
# Neo4j Community Edition AMI Build Script
#
# This script prepares an Amazon Linux 2023 instance as a base OS image
# for the Neo4j CE Marketplace listing. Neo4j itself is installed at
# deploy time from yum.neo4j.com via the CloudFormation UserData script.
#
# What this script does:
#   - Patches the OS (required for Marketplace AMI security scanning)
#   - Hardens SSH (required by AWS Marketplace AMI policies)
#   - Cleans up caches to reduce AMI size
#
# Prerequisites:
#   - Run on a fresh Amazon Linux 2023 EC2 instance in us-east-1
#   - Run as root (or via sudo)
#   - Instance must be in the neo4j-marketplace AWS account
#
# After running this script, create an AMI from the instance and register
# it with --imds-support v2.0. See marketplace/README.md for full steps.
#
# Reference: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/building-shared-amis.html

set -euo pipefail

echo "=== Neo4j CE Base AMI Build ==="

# --- Step 1: Patch the OS ---
# Required by Marketplace AMI scanning to ensure all CVEs are patched.
echo "Patching OS..."
dnf update -y

# --- Step 2: SSH Hardening ---
# Required by AWS Marketplace AMI security policies.
# Reference: https://docs.aws.amazon.com/marketplace/latest/userguide/best-practices-for-building-your-amis.html

# Disable password-based remote logins for root.
# AL2023 ships with "#PermitRootLogin prohibit-password" (commented).
# We uncomment and set it explicitly so Marketplace scanning sees a clear value.
# "prohibit-password" is the modern equivalent of "without-password".
sed -i 's/^#PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# Ensure SSH password authentication is disabled.
# AL2023 may already have this set via cloud-init presets, but we make it explicit.
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Disable sshd DNS checks — prevents SSH login failures when DNS is unavailable.
# Remove any existing UseDNS line (commented or not) then append a clean value.
sed -i '/UseDNS/d' /etc/ssh/sshd_config
echo "UseDNS no" >> /etc/ssh/sshd_config

# Disable local root access
passwd -l root

# Remove SSH host key pairs (regenerated on first boot)
shred -u /etc/ssh/*_key /etc/ssh/*_key.pub

# Remove any authorized keys
rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys

# --- Step 3: Clean up ---
# Remove yum cache to reduce AMI size
dnf clean all
rm -rf /var/cache/dnf

# Remove temporary files
rm -rf /tmp/* /var/tmp/*

# Clear shell history — required by shared AMI guidelines to avoid leaking
# credentials or commands run during the build session.
shred -u /root/.bash_history 2>/dev/null || rm -f /root/.bash_history

echo "=== Build complete ==="
echo "Next steps:"
echo "  1. Stop the instance (do NOT terminate)"
echo "  2. Create AMI from the instance"
echo "  3. Register with: aws ec2 register-image --imds-support v2.0 ..."
echo "  See marketplace/README.md for full instructions."

# Shut down the instance for AMI creation
shutdown -h now
