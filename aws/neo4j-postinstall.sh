#!/bin/bash

echo '#########################################'
echo '########## NEO4J POST-INSTALL ###########'
echo '#########################################'

# Provisioned copy of conf needs to be put in place.
sudo cp /home/ubuntu/neo4j.conf /etc/neo4j/neo4j.template
sudo cp /home/ubuntu/pre-neo4j.sh /etc/neo4j/pre-neo4j.sh
sudo chmod +x /etc/neo4j/pre-neo4j.sh

# Edit startup profile for this system service to call our pre-neo4j wrapper (which in turn
# runs neo4j).  The wrapper grabs key/values from cloud environment and dynamically re-writes
# neo4j.conf at startup time to properly configure it for network environment.
sudo sed -i 's/ExecStart=.*$/ExecStart=\/etc\/neo4j\/pre-neo4j.sh/' /etc/systemd/system/neo4j.service

sudo systemctl daemon-reload
sudo systemctl restart neo4j

sleep 20
echo "After re-configuration, service status"
sudo systemctl status neo4j
