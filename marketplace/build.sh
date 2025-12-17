#!/bin/sh

# Detail on the cleanup steps below is here.
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/building-shared-amis.html

sudo su

# Disable password-based remote logins for root
sed -i 's/#PermitRootLogin yes/PermitRootLogin without-password/g' /etc/ssh/sshd_config

# Disable local root access
sudo passwd -l root

# Remove SSH host key pairs
sudo shred -u /etc/ssh/*_key /etc/ssh/*_key.pub

shutdown -h now