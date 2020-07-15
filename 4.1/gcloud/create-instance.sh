#!/bin/bash
IMAGE=$1
PROJECT=launcher-development-191917
ZONE=us-east1-b

if [ -z $IMAGE ]; then
   echo "Call me with the name of an image"
   exit 1
fi

gcloud compute instances create "instance-$IMAGE" \
   --scopes https://www.googleapis.com/auth/cloud-platform \
   --image-project $PROJECT \
   --tags neo4j \
   --image=$IMAGE
