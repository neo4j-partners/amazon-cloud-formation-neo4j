#!/bin/bash

if [ -z $1 ]; then
   echo "Requires argument of DBID"
   exit 1
fi

if [ -z $TOKEN ] ; then
   echo "Requires TOKEN to be defined (bearer token for auth)"   
   exit 1
fi

DBID=$1

ENDPOINT=https://console.neo4j.io/databases/$1
AUTH="Bearer $TOKEN"

echo "DELETE of Neo4j Cloud here: " $1
echo "https://console.neo4j.io/#databases"

RESPONSE=$(curl --header "Content-Type: application/json" \
   --header "Authorization: $AUTH" \
   --request DELETE $ENDPOINT)
EC=$?

echo $RESPONSE
echo $RESPONSE | jq -r ".message"

exit $EC