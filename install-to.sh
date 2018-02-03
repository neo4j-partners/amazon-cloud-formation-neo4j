#!/bin/bash
#
# Install local working copy of the neo4j template to the VM.
#
for machine in 'cc-core-follower' ; do
  echo "Installing to " $machine
  gcloud compute scp README.md $machine:/tmp/README.md
  gcloud compute ssh $machine --command="sudo cp /tmp/README.md /etc/neo4j/README.md"
  gcloud compute scp neo4j.conf $machine:/tmp/neo4j.template
  gcloud compute ssh $machine --command="sudo cp /tmp/neo4j.template /etc/neo4j/neo4j.template"
  gcloud compute scp pre-neo4j.sh $machine:/tmp/ 
  gcloud compute ssh $machine --command="sudo cp /tmp/pre-neo4j.sh /etc/neo4j/pre-neo4j.sh"
done

