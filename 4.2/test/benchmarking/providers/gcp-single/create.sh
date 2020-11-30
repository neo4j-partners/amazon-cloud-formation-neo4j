#!/bin/bash
export RUN_ID=$(head -c 1024 /dev/urandom | md5)
export PROJECT=testbed-187316
export MACHINE=n1-standard-2
# export DISK_TYPE=pd-standard
export DISK_TYPE=pd-ssd
export DISK_SIZE=64GB
export ZONE=us-east1-b
export NEO4J_VERSION=4.2.1
export PASSWORD=$(head -n 20 /dev/urandom | md5)
export STACK_NAME=neo4j-testdeploy-$(head -c 3 /dev/urandom | md5 | head -c 5)

# Setup firewalling.
echo "Creating firewall rules"
gcloud compute firewall-rules create "$STACK_NAME" \
   --allow tcp:7473,tcp:7687 \
   --source-ranges 0.0.0.0/0 \
   --target-tags neo4j \
   --project $PROJECT

if [ $? -ne 0 ] ; then
    echo "Firewall creation failed.  Bailing out"
    exit 1
fi

echo "Creating instance"
OUTPUT=$(gcloud compute instances create $STACK_NAME \
    --project $PROJECT \
    --image neo4j-enterprise-1-4-2-0-apoc \
    --tags neo4j \
    --machine-type $MACHINE \
    --boot-disk-size $DISK_SIZE \
    --boot-disk-type $DISK_TYPE \
    --image-project launcher-public)
EC=$?
echo $OUTPUT

# Pull out the IP addresses, and toss out the private internal one (10.*)
IP=$(echo $OUTPUT | grep -oE '((1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])\.){3}(1?[0-9][0-9]?|2[0-4][0-9]|25[0-5])' | grep --invert-match "^10\.")
echo "Discovered new machine IP at $IP"

tries=0
while true ; do
   OUTPUT=$(echo "CALL dbms.changePassword('$PASSWORD');" | cypher-shell -a $IP -u neo4j -p "neo4j" 2>&1)
   EC=$?

   echo $OUTPUT

   if [ $EC -eq 0 ]; then
      echo "Machine is up ... $tries tries"
      break
   fi

   if [ $tries -gt 30 ] ; then
      echo STACK_NAME=$STACK_NAME
      echo "Machine is not coming up, giving up"
      exit 1
   fi
   
   tries=$(($tries+1))
   echo "Machine is not up yet ... $tries tries"
   sleep 1;
done

echo BENCHMARK_SETTING_ZONE=$ZONE
echo BENCHMARK_SETTING_MACHINE_TYPE=$MACHINE
echo BENCHMARK_SETTING_NEO4J_VERSION=$NEO4J_VERSION
echo BENCHMARK_SETTING_PROJECT=$PROJECT
echo BENCHMARK_SETTING_DISK_TYPE=$DISK_TYPE
echo BENCHMARK_SETTING_DISK_SIZE=$DISK_SIZE

echo NEO4J_URI=bolt://$IP:7687
echo NEO4J_PASSWORD=$PASSWORD
echo STACK_NAME=$STACK_NAME
echo RUN_ID=$RUN_ID
exit 0