#!/bin/bash

export PROJECT=testbed-187316

if [ -z $1 ] ; then
   echo "Missing argument"
   exit 1
fi

echo "Deleting instance and firewall rules"
gcloud compute instances delete --quiet "$1" --project "$PROJECT" && gcloud compute firewall-rules --quiet delete "$1" --project "$PROJECT"
exit $?
