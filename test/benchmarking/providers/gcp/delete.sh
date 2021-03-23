#!/bin/bash

PROJECT=testbed-187316

if [ -z $1 ] ; then
  echo "Usage: call me with deployment name"
  exit 1
fi

gcloud -q deployment-manager deployments delete $1 --project $PROJECT

# Delete leftover disks; the deploy process leaves these to avoid
# destroying data but we don't want to leak disks
gcloud --quiet compute disks delete $(gcloud compute disks list --project $PROJECT --filter="name~'$1'" --uri)