#!/bin/bash

if [ -z $TOKEN ] ; then
   echo "Requires TOKEN to be defined (bearer token for auth)"
   exit 1
fi

ENDPOINT=https://console.neo4j.io/databases
AUTH="Bearer $TOKEN"
dbid=$1

echo "===== $dbid"
curl --header "Content-Type: application/json" \
    --header "Authorization: $AUTH" \
    --request GET \
    $ENDPOINT/$dbid ;
