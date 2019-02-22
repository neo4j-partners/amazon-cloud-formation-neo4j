#!/bin/bash

if [ -z $1 ] ; then
  echo "Usage: call me with deployment name"
  exit 1
fi

az group delete -n "$1" --no-wait --yes
