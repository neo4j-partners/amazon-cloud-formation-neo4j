#!/bin/bash
# Instructions stolen from standard docs.
# https://neo4j.com/docs/operations-manual/current/installation/linux/debian/

echo '#########################################'
echo '####### BEGINNING NEO4J INSTALL #########'
echo '#########################################'

echo "neo4j-enterprise neo4j/question select I ACCEPT" | sudo debconf-set-selections
echo "neo4j-enterprise neo4j/license note" | sudo debconf-set-selections

wget -O - https://debian.neo4j.org/neotechnology.gpg.key | sudo apt-key add -
echo 'deb http://debian.neo4j.org/repo stable/' | sudo tee -a /etc/apt/sources.list.d/neo4j.list
sudo apt-get update

if [ $neo4j_edition = "community" ]; then
    sudo apt-get --yes install neo4j=$neo4j_version
else
    sudo apt-get --yes install neo4j-enterprise=$neo4j_version
fi

echo "Enabling neo4j system service"

# Intending to use systemd scripts, not vanilla ubuntu /etc/init.d startups.
sudo cp /lib/systemd/system/neo4j.service /etc/systemd/system/neo4j.service
sudo systemctl enable neo4j
echo "Starting neo4j..."
sudo systemctl start neo4j

# Install ancillary tools necessary for config/monitoring.
sudo apt-get --yes install jq python python-setuptools

echo "Available system services"
ls /etc/systemd/system

echo ''
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

echo "Daemon reload and restart"
sudo systemctl daemon-reload
sudo systemctl restart neo4j

sleep 20
echo "After re-configuration, service status"
sudo systemctl status neo4j
sudo journalctl -u neo4j -b

echo ''
echo '#########################################'
echo '########## NEO4J SETUP COMPLETE #########'
echo '#########################################'
