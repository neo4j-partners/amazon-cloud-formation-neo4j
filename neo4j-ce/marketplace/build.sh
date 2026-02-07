#!/bin/bash
# Neo4j Community Edition AMI Build Script
#
# This script prepares an Amazon Linux 2023 instance for use as a
# Neo4j CE Marketplace AMI. It follows the hybrid AMI approach:
# pre-bake Java and Neo4j into the image, configure at boot via UserData.
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

echo "=== Neo4j CE AMI Build ==="

# --- Step 1: Patch the OS ---
# Required by Marketplace AMI scanning to ensure all CVEs are patched.
echo "Patching OS..."
dnf update -y

# --- Step 2: Install Java 21 ---
# Neo4j 2025.x requires Java 21. Amazon Corretto is the recommended JVM on Amazon Linux.
echo "Installing Java 21 (Amazon Corretto)..."
dnf install -y java-21-amazon-corretto-headless

# --- Step 3: Install Neo4j Community Edition from yum ---
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

# --- Step 4: Raise file descriptor limit ---
# Neo4j Operations Manual recommends 60000. Linux default (1024) is too low.
# Reference: https://neo4j.com/docs/operations-manual/current/installation/linux/
mkdir -p /etc/systemd/system/neo4j.service.d
cat > /etc/systemd/system/neo4j.service.d/override.conf <<'CONF'
[Service]
LimitNOFILE=60000
CONF

# --- Step 5: SSH Hardening ---
# Required by AWS Marketplace AMI security policies.
# Reference: https://docs.aws.amazon.com/marketplace/latest/userguide/best-practices-for-building-your-amis.html

# Disable password-based remote logins for root
sed -i 's/#PermitRootLogin yes/PermitRootLogin without-password/g' /etc/ssh/sshd_config

# Ensure SSH password authentication is disabled
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config

# Disable local root access
passwd -l root

# Remove SSH host key pairs (regenerated on first boot)
shred -u /etc/ssh/*_key /etc/ssh/*_key.pub

# Remove any authorized keys
rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys

# --- Step 6: Clean up ---
# Remove yum cache to reduce AMI size
dnf clean all
rm -rf /var/cache/dnf

# Remove temporary files
rm -rf /tmp/* /var/tmp/*

echo "=== Build complete ==="
echo "Next steps:"
echo "  1. Stop the instance (do NOT terminate)"
echo "  2. Create AMI from the instance"
echo "  3. Register with: aws ec2 register-image --imds-support v2.0 ..."
echo "  See marketplace/README.md for full instructions."

# Shut down the instance for AMI creation
shutdown -h now
