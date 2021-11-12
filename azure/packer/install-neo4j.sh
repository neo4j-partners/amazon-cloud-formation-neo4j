#!/bin/bash
# Instructions stolen from standard docs.
# https://neo4j.com/docs/operations-manual/current/installation/linux/debian/

echo '#########################################'
echo '#######        SYSTEM UPDATE    #########'
echo '#########################################'

echo "neo4j-enterprise neo4j/question select I ACCEPT" | sudo debconf-set-selections
echo "neo4j-enterprise neo4j/license note" | sudo debconf-set-selections

wget -O - https://debian.neo4j.com/neotechnology.gpg.key | sudo apt-key add -
echo 'deb https://debian.neo4j.com stable 4.3' | sudo tee -a /etc/apt/sources.list.d/neo4j.list
sudo add-apt-repository universe
sudo add-apt-repository -y ppa:openjdk-r/ppa
sudo apt-get update

#Create directories
sudo mkdir -p /etc/neo4j
sudo chown "${userid}":"${groupid}" "/etc/neo4j"
sudo mkdir -p /var/lib/neo4j/logs
sudo chown "${userid}":"${groupid}" "/var/lib/neo4j/logs"
sudo mkdir -p /var/lib/neo4j/conf
sudo chown "${userid}":"${groupid}" "/var/lib/neo4j/conf"
sudo mkdir -p /var/lib/neo4j/metrics
sudo chown "${userid}":"${groupid}" "/var/lib/neo4j/metrics"
sudo mkdir -p /var/lib/neo4j/plugins
sudo chown "${userid}":"${groupid}" "/var/lib/neo4j/plugins"

echo '#########################################'
echo '####### BEGINNING NEO4J INSTALL #########'
echo '#########################################'

if [ $neo4j_edition = "community" ]; then
    echo "neo4j=$neo4j_version"
    sudo apt-get --yes install neo4j=$neo4j_version
else
    echo "neo4j-enterprise=$neo4j_version"
    sudo apt-get --yes install neo4j-enterprise=$neo4j_version
fi

if [ $? -ne 0 ] ; then
    echo '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@'
    echo '########## NEO4J INSTALL FAILED #########'
    echo '@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@'
    exit 1
fi

echo "Enabling neo4j system service"

# Intending to use systemd scripts, not vanilla ubuntu /etc/init.d startups.
sudo cp /lib/systemd/system/neo4j.service /etc/systemd/system/neo4j.service
sudo systemctl enable neo4j

# Install ancillary tools necessary for config/monitoring.
# Azure tools get installed here.
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | \
    sudo tee /etc/apt/sources.list.d/azure-cli.list
curl -L https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -
sudo apt-get update
sudo apt-get --yes install apt-transport-https azure-cli jq

echo "Available system services"
ls /etc/systemd/system

# Instance metadata:
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html#instancedata-data-retrieval
curl --silent http://169.254.169.254/latest/meta-data/public-hostname

echo ''
echo '#########################################'
echo '########## NEO4J POST-INSTALL ###########'
echo '#########################################'

# Provisioned copy of conf needs to be put in place.
if [ $neo4j_edition = "community" ]; then
    sudo cp /home/ubuntu/neo4j-community.conf /etc/neo4j/neo4j.template
else
    sudo cp /home/ubuntu/neo4j.conf /etc/neo4j/neo4j.template
fi

sudo cp /home/ubuntu/pre-neo4j.sh /etc/neo4j/pre-neo4j.sh
sudo cp -r /home/ubuntu/licensing /var/lib/neo4j
sudo chmod +x /etc/neo4j/pre-neo4j.sh

# Edit startup profile for this system service to call our pre-neo4j wrapper (which in turn
# runs neo4j).  The wrapper grabs key/values from cloud environment and dynamically re-writes
# neo4j.conf at startup time to properly configure it for network environment.
sudo sed -i 's/ExecStart=.*$/ExecStart=\/etc\/neo4j\/pre-neo4j.sh/' /etc/systemd/system/neo4j.service

install_plugin () {
    name=$1
    url=$2

    if [ -z $url ] ; then
        echo "Skipping plugin install of $name - URL is not set"
    else
        jarname=$(basename "$url")
        cd /tmp && curl -L "$url" -O
        sudo mv "/tmp/$jarname" /var/lib/neo4j/plugins

        if [ $? -eq 0 ]; then
            echo "Plugin $name successfully installed:"
            ls -l "/var/lib/neo4j/plugins/$jarname"
            md5sum "/var/lib/neo4j/plugins/$jarname"
        else
            echo "Plugin $name install FAILED"
        fi
    fi
}

echo ''
echo '#########################################'
echo '########## NEO4J PLUGIN INSTALL #########'
echo '#########################################'

install_plugin "APOC" "$apoc_jar"
install_plugin "BLOOM" "$bloom_jar"

echo "Daemon reload and restart"
sudo systemctl daemon-reload
sudo systemctl restart neo4j

sleep 10
echo "After re-configuration, service status"
sudo systemctl status neo4j
sudo journalctl -u neo4j -b

echo ''
echo '#########################################'
echo '########## NEO4J SETUP COMPLETE #########'
echo '#########################################'