#!/bin/bash
export RUN_ID=$(head -c 1024 /dev/urandom | md5)
PROJECT=neo4j-k8s-marketplace-public
CLUSTER=benchmark-$(head -c 3 /dev/urandom | md5 | head -c 5)
ZONE=us-central1-a
NODES=3
API=beta
NEO4J_VERSION=3.5.1-enterprise

echo "Deleting stack $1"

gcloud beta container clusters delete $1 \
   --zone us-central1-a \
   --project $PROJECT
