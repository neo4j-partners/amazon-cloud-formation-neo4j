#!/bin/bash
#
# Google Compute Metadata API Docs:
# https://cloud.google.com/compute/docs/storing-retrieving-metadata
#
# Get our external IP from the google metadata catalog.
echo "pre-neo4j.sh: Fetching GCP instance metadata"

export INSTANCE_API=http://metadata.google.internal/computeMetadata/v1/instance

export EXTERNAL_IP_ADDR=$(curl -s -H "Metadata-Flavor: Google" \
   $INSTANCE_API/network-interfaces/0/access-configs/0/external-ip)

echo "pre-neo4j.sh: External IP $EXTERNAL_IP_ADDR"

export INTERNAL_HOSTNAME=$(curl -s -H "Metadata-Flavor: Google" \
   $INSTANCE_API/hostname) 

echo "pre-neo4j.sh Internal hostname $INTERNAL_HOSTNAME"

# Fetch cluster members metadata.  If this isn't defined, it will return HTML
# error.  Grep for the expected port to make sure the var is empty if the metadata
# isn't defined.
export MEMBERS=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/cluster-members | grep :5000)

# Ensure cluster members are defined no matter what, with a reasonable default.
export CLUSTER_MEMBERS=${MEMBERS:-neo4j1:5000,neo4j2:5000,neo4j3:5000}

echo "pre-neo4j.sh: configured members $CLUSTER_MEMBERS"

# Google VMs don't have ifconfig.
# Output of ip addr looks like this:

# 2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1460 qdisc pfifo_fast state UP group default qlen 1000
#   link/ether 42:01:0a:8a:00:04 brd ff:ff:ff:ff:ff:ff
#   inet 10.138.0.4/32 brd 10.138.0.4 scope global eth0
#      valid_lft forever preferred_lft forever
#   inet6 fe80::4001:aff:fe8a:4/64 scope link 
#      valid_lft forever preferred_lft forever
# So we're pulling just the 10.138.0.4 part.

export INTERNAL_IP_ADDR=$(ip addr | grep brd | grep eth0 | cut -d ' ' -f 8)

echo "pre-neo4j.sh internal IP $INTERNAL_IP_ADDR"

echo "pre-neo4j.sh: setting up configuration"
# Run substitutions to make sure we have the right address.
envsubst < /etc/neo4j/neo4j.template > /etc/neo4j/neo4j.conf

echo "pre-neo4j.sh: Starting neo4j console..."

# This is the same command sysctl's service would have executed.
/usr/share/neo4j/bin/neo4j console
