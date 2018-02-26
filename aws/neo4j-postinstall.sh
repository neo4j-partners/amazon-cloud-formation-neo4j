#!/bin/bash

# Provisioned copy of conf needs to be put in place.
sudo cp /home/ubuntu/neo4j.conf /etc/neo4j/neo4j.conf

sudo systemctl restart neo4j

