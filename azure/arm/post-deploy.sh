#!/bin/bash
#
# This script is a set of hooks that run after Neo4j VMs are deployed.
# Right now it doesn't do much, but provides a location for any extensions that need
# to happen on top of the base VM developed from packer.
########################################################################################
LOGFILE=~/post-deploy.log
echo `date` | tee -a $LOGFILE
echo "Post deploy actions complete" 2>&1 | tee -a $LOGFILE
env 2>&1 | tee -a $LOGFILE
sudo apt-get update 2>&1 | tee -a $LOGFILE

