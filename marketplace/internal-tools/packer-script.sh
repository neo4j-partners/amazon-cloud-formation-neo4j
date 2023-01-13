#!/bin/bash

sudo rm -f ~/.ssh/authorized_keys
sudo rm -f /root/.ssh/authorized_keys
sudo rpm --import https://debian.neo4j.com/neotechnology.gpg.key

sudo bash -c 'cat > /etc/yum.repos.d/neo4j.repo' << EOF
[neo4j]
name=Neo4j Yum Repo
baseurl=http://yum.neo4j.com/stable/4.4
enabled=1
gpgcheck=1
EOF

sudo yum install --downloadonly neo4j-enterprise
sudo yum install -y jq
