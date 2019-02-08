#!/bin/bash
#
# Usage:  scrape the bearer token out of your http sessions
# export TOKEN=whatever
# ./create.sh
# That's it!
export RUN_ID=$(head -c 1024 /dev/urandom | md5)

if [ -z $TOKEN ] ; then
   echo "Requires TOKEN to be defined (bearer token for auth)"
   exit 1
fi

echo "================================================================"
echo "David's highly experimental auto-Neo4j-cloud-provisioner-thingy"
echo "FEATURES:"
echo '- Totally unsupported!'
echo '- Mess of bash!'
echo '- 50% more cloud water vapor!'
echo '- 1000% more danger!'
echo "================================================================"

export DEPLOY_ID=$(head -c 10 /dev/urandom | md5 | head -c 5)
export NAME=benchmark-$DEPLOY_ID

JSON='{"Name": "'$NAME'", "Downtime": "00:00 Thu Europe/London"}'
ENDPOINT=https://console.neo4j.io/databases
AUTH="Bearer $TOKEN"

echo $JSON

RESPONSE=$(curl --header "Content-Type: application/json" \
  --header "Authorization: $AUTH" \
  --request POST \
  --data "$JSON" \
  $ENDPOINT 2>/dev/null)
EC=$?

echo $RESPONSE

if [ $EC -ne 0 ]  ; then
    echo "Creation seems to have failed.  Bailing"
    exit 1
fi

DB_ID=$(echo $RESPONSE | jq -r '.DbId')
PASSWORD=$(echo $RESPONSE | jq -r '.Password')

echo "DB_ID=$DB_ID and PASSWORD=$PASSWORD from JSON"
echo "Waiting for basic creation"
sleep 30

DB_ENDPOINT=https://console.neo4j.io/databases/$DB_ID

# Sleep 6 seconds at a time, 10 total minutes of attempts
tries=0
MAX_TRIES=100
SLEEP_TIME=6

while true ; do
   RESPONSE=$(curl --header "Content-Type: application/json" \
       --header "Authorization: $AUTH" \
       --request GET $DB_ENDPOINT 2>/dev/null)
   EC=$?

    # Output looks like this:
    # {
    # "BoltUrl": "bolt+routing://522b799d.databases.neo4j.io", 
    # "BrowserUrl": "https://522b799d.databases.neo4j.io", 
    # "DatabaseStatus": "running", 
    # "DbId": "522b799d", 
    # "Downtime": "*:15 * UTC", 
    # "MonitoringStatus": "ok", 
    # "Name": "benchmark-310c5"
    # }

   echo $RESPONSE

   NEO4J_URI=$(echo $RESPONSE | jq -r ".BoltUrl")
   DB_STATUS=$(echo $RESPONSE | jq -r ".DatabaseStatus")  

   echo "====== Status: $DB_STATUS" `date`

   if [ "$DB_STATUS" = "running" ] ; then
       echo 'Woot!  Looks like we are up and ready to go'
       echo "So graph.  Very cloud.  Much GKE.  Wow."
       break
   fi

   if [ $tries -gt $MAX_TRIES ] ; then
       echo "Investigate....it is not coming up    :("
       exit 1
   fi

   tries=$(($tries+1))
   echo "Database not yet up .... $tries tries"
   sleep $SLEEP_TIME ; 
done

echo $RESPONSE

# Provider API requirements.
echo BENCHMARK_SETTING_MANUAL=true
echo BENCHMARK_SETTING_CLOUD_BASE=gke
echo NEO4J_URI=$NEO4J_URI
echo NEO4J_PASSWORD=$PASSWORD
echo STACK_NAME=$DB_ID
echo RUN_ID=$RUN_ID
exit 0