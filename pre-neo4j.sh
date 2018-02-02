#!/bin/bash

# Get our external IP from the google metadata catalog.
export EXTERNAL_IP_ADDR=$(curl -s -H "Metadata-Flavor: Google" \
   http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

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

# Run substitutions to make sure we have the right address.
envsubst < /tmp/neo4j.template > /tmp/neo4j.conf

echo "Setting up configuration"
sudo cp /tmp/neo4j.conf /etc/neo4j/neo4j.conf

