#!/bin/bash
# Instructions stolen from standard docs.
# https://neo4j.com/docs/operations-manual/current/installation/linux/debian/


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

sudo systemctl enable neo4j
sudo systemctl start neo4j

# Instance metadata:
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html#instancedata-data-retrieval
curl http://169.254.169.254/latest/meta-data/public-hostname
