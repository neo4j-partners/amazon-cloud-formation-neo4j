#!/bin/bash

# Get our external IP from the google metadata catalog.
export IP_ADDR=$(curl -s -H "Metadata-Flavor: Google" \
   http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

# Run substitutions to make sure we have the right address.
sudo envsubst < /tmp/neo4j.template > /etc/neo4j/neo4j.conf

sudo service neo4j restart
