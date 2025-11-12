#!/bin/sh

# This script is intended to be run in the private image build feature of AWS Marketplace.
# The relevant doc is here:
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/building-shared-amis.html

# Disable password-based remote logins for root
sed -i 's/#PermitRootLogin yes/PermitRootLogin without-password/g' /etc/ssh/sshd_config

# Disable local root access
sudo passwd -l root

# Remove SSH host key pairs
sudo shred -u /etc/ssh/*_key /etc/ssh/*_key.pub