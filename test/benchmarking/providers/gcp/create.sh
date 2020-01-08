#!/bin/bash

export RUN_ID=$(head -c 1024 /dev/urandom | md5)
export NAME=neo4j-testdeploy-$(head -c 3 /dev/urandom | md5 | head -c 5)
PROJECT=testbed-187316
# 2 CPUs, 7.5gb RAM
MACHINE=n1-standard-2
# DISK_TYPE=pd-standard
DISK_TYPE=pd-ssd
DISK_SIZE=64
ZONE=us-east1-b
CORES=3
READ_REPLICAS=0
NEO4J_VERSION=3.5.14
TEMPLATE_URL=https://storage.googleapis.com/neo4j-deploy/$NEO4J_VERSION/causal-cluster/neo4j-causal-cluster.jinja

OUTPUT=$(gcloud deployment-manager deployments create $NAME \
    --project $PROJECT \
    --template "$TEMPLATE_URL" \
    --properties "zone:'$ZONE',clusterNodes:'$CORES',readReplicas:'$READ_REPLICAS',bootDiskSizeGb:$DISK_SIZE,bootDiskType:'$DISK_TYPE',machineType:'$MACHINE'")
echo $OUTPUT

echo BENCHMARK_SETTING_ZONE=$ZONE
echo BENCHMARK_SETTING_CORE_NODES=$CORES
echo BENCHMARK_SETTING_READ_REPLICAS=$READ_REPLICAS
echo BENCHMARK_SETTING_MACHINE_TYPE=$MACHINE
echo BENCHMARK_SETTING_GCP_PROJECT=$PROJECT
echo BENCHMARK_SETTING_DISK_TYPE=$DISK_TYPE
echo BENCHMARK_SETTING_DISK_SIZE=$DISK_SIZE
echo BENCHMARK_SETTING_NEO4J_VERSION=$NEO4J_VERSION

PASSWORD=$(echo $OUTPUT | perl -ne 'm/password\s+([^\s]+)/; print $1;')
IP=$(echo $OUTPUT | perl -ne 'm/vm1URL\s+https:\/\/([^\s]+):/; print $1; ')

echo NEO4J_URI=bolt+routing://$IP
echo NEO4J_PASSWORD=$PASSWORD
echo STACK_NAME=$NAME
echo RUN_ID=$RUN_ID
