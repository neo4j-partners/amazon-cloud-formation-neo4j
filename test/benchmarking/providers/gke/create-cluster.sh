#!/bin/bash
export RUN_ID=$(head -c 1024 /dev/urandom | md5)
PROJECT=neo4j-k8s-marketplace-public
CLUSTER=benchmark-$(head -c 3 /dev/urandom | md5 | head -c 5)
ZONE=us-central1-a
NODES=3
API=beta
NEO4J_VERSION=3.5.1-enterprise

gcloud beta container clusters create $CLUSTER \
    --zone "$ZONE" \
    --project $PROJECT \
    --machine-type "n1-standard-4" \
    --num-nodes "3" \
    --max-nodes "10" \
    --enable-autoscaling

echo "CLUSTER=$CLUSTER"
echo "ZONE=$ZONE"

echo RUN_ID=$RUN_ID
echo NEO4J_URI=bolt+routing://TBD
echo NEO4J_PASSWORD=$NEO4J_PASSWORD
echo STACK_NAME=$STACK_NAME
