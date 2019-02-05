#!/bin/bash

export RUN_ID=$(head -c 1024 /dev/urandom | md5)
export NAME=neo4j-testdeploy-$(head -c 3 /dev/urandom | md5 | head -c 5)
PROJECT=testbed-187316
MACHINE=n1-standard-4

OUTPUT=$(gcloud deployment-manager deployments create $NAME \
    --project $PROJECT \
    --template ../../../../gcloud/solutions/causal-cluster/neo4j-causal-cluster.jinja \
    --properties "clusterNodes:'3',readReplicas:'0',machineType:'$MACHINE'")
echo $OUTPUT

PASSWORD=$(echo $OUTPUT | perl -ne 'm/password\s+([^\s]+)/; print $1;')
IP=$(echo $OUTPUT | perl -ne 'm/vm1URL\s+https:\/\/([^\s]+):/; print $1; ')

echo NEO4J_IP=$IP
echo NEO4J_PASSWORD=$PASSWORD
echo STACK_NAME=$NAME
echo RUN_ID=$RUN_ID
