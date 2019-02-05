#!/bin/bash

if [ -z $1 ] ; then
  echo "Usage: call me with deployment name"
  exit 1
fi

gcloud -q deployment-manager deployments delete $1 --project testbed-187316
