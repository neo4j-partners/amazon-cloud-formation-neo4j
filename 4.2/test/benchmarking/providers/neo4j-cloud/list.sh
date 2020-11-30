#!/bin/bash

if [ -z $TOKEN ] ; then
   echo "Requires TOKEN to be defined (bearer token for auth)"
   exit 1
fi

ENDPOINT=https://console.neo4j.io/databases
AUTH="Bearer $TOKEN"

RESPONSE=$(curl --header "Content-Type: application/json" \
  --header "Authorization: $AUTH" \
  --request GET \
  --data "$JSON" \
  $ENDPOINT 2>/dev/null)
EC=$?

if [ $EC -ne 0 ] ; then
    echo "Failed - check your token"
    exit 1
fi

echo $RESPONSE

for dbid in $(echo $RESPONSE | jq -r ".[].DbId") ; do
   echo "===== $dbid"
   curl --header "Content-Type: application/json" \
      --header "Authorization: $AUTH" \
      --request GET \
      $ENDPOINT/$dbid 2>/dev/null ; 
done
