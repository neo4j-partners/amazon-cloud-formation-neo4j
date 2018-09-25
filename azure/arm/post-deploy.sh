#!/bin/bash
#
# This script is a set of hooks that run after Neo4j VMs are deployed.
# Right now it doesn't do much, but provides a location for any extensions that need
# to happen on top of the base VM developed from packer.
########################################################################################
LOGFILE=/root/post-deploy-setup.log

echo `date` | tee -a $LOGFILE
env 2>&1 | tee -a $LOGFILE

# echo "CLOUDMARK" >> /var/log/neo4j/debug.log

sudo apt-get update 2>&1 | tee -a $LOGFILE

# Loop waiting for neo4j service to start.
while true; do
    if curl -s -I http://localhost:7474 | grep '200 OK'; then
        echo `date` 'Neo4j is up; changing default password' 2>&1 | tee -a $LOGFILE
        curl -v -H 'Content-Type: application/json' \
                -XPOST -d '{"password":"'$NEO4J_PASSWORD'"}' \
                -u neo4j:neo4j \
                http://localhost:7474/user/neo4j/password \
                2>&1 | tee -a $LOGFILE
        
        echo `date` 'Password reset; a graph user is you!' 2>&1 | tee -a $LOGFILE
        echo `date` 'Startup complete ' | tee -a $LOGFILE
        break
    fi

    echo `date` 'Waiting for neo4j to come up' 2>&1 | tee -a $LOGFILE
    sleep 1
done

echo "Finished Neo4j setup" | tee -a $LOGFILE