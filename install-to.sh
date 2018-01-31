#!/bin/bash

for machine in 'cc-core-lead' 'cc-core-follower' 'cc-core-follower-2'; do
  echo "Installing to " $machine
  gcloud compute scp neo4j.conf $machine:/tmp/neo4j.template
  gcloud compute scp config-and-run.sh $machine:/tmp/ ;
done

