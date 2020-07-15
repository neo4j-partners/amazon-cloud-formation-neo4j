#!/bin/bash

if [ -z $1 ] ; then
  echo "Usage: call me with deployment name"
  exit 1
fi

echo "Deleting /tmp/$1"
rm -rf "/tmp/$1"
docker rm -f "$1"
echo "Done destroying container $1"