#!/bin/bash
set -e
export VERSION=3.5.21
#export STACKVERSION=3-5-16

#export NEO4J_USERNAME=neo4j
#export NEO4J_PASSWORD=
#export CORES=3
#export READ_REPLICAS=1
#export STACKNAME=neo4j-single-testdeploy-$(echo $STACKVERSION)

#rm -f $HOME/.aws/config
#mkdir $HOME/.aws/
#envsubst < "config" > "$HOME/.aws/config"
#envsubst < "s3cfg" > "/root/.s3cfg"
#envsubst < "s3cfg-marketplace" > "/root/.s3cfg-marketplace"
#envsubst < "s3cfg-govcloud" > "/root/.s3cfg-govcloud"
export AWS_PROFILE=marketplace
cd /app/aws/packer
./packer-deploy.sh