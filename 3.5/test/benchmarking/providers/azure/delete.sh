#!/bin/bash
# Simply deletes an entire resource group.
# Since the cluster is contained to an RG, this tears down everything.
if [ -z $1 ] ; then
  echo "Usage: call me with deployment name"
  exit 1
fi

STACK_NAME=$1

if [ -f "$STACK_NAME.json" ] ; then
   rm -f "$STACK_NAME.json"
fi

az group delete -n "$STACK_NAME" --no-wait --yes
exit $?