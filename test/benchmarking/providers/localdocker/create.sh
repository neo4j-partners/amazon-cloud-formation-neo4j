#!/bin/bash

export RUN_ID=$(head -c 1024 /dev/urandom | md5)
PASSWORD=admin
CWD=`pwd`
<<<<<<< HEAD:test/benchmarking/providers/localdocker/create.sh
NEO4J=neo4j:4.3.0-enterprise
=======
NEO4J=neo4j:4.3.2-enterprise
>>>>>>> neo4j-v4.3.0:4.1/test/benchmarking/providers/localdocker/create.sh
PAGE_CACHE=1G
INITIAL_HEAP=2G
MAX_HEAP=4G
CONTAINER=benchmark-neo4j-$RUN_ID

APOC_VERSION=4.1.0.1
APOC=https://github.com/neo4j-contrib/neo4j-apoc-procedures/releases/download/$APOC_VERSION/apoc-$APOC_VERSION-all.jar
mkdir /tmp/$CONTAINER && wget -P /tmp/$CONTAINER $APOC

# Output some stack settings.
echo STACK_SETTING_PAGE_CACHE=$PAGE_CACHE
echo STACK_SETTING_INITIAL_HEAP=$INITIAL_HEAP
echo STACK_SETTING_MAX_HEAP=$MAX_HEAP
echo STACK_SETTING_NEO4J=$NEO4J
echo STACK_SETTING_APOC_VERSION=$APOC_VERSION

echo $CONTAINER
docker run -d --name "$CONTAINER" --rm \
        -p 127.0.0.1:7474:7474 \
        -p 127.0.0.1:7687:7687 \
        --env=NEO4J_dbms_memory_pagecache_size=$PAGE_CACHE \
        --env=NEO4J_dbms_memory_heap_initial__size=$INITIAL_HEAP \
        --env=NEO4J_dbms_memory_heap_max__size=$MAX_HEAP \
        --env NEO4J_AUTH=neo4j/$PASSWORD \
        --volume=/tmp/$CONTAINER:/plugins \
        --env=NEO4J_ACCEPT_LICENSE_AGREEMENT=yes \
        --env NEO4J_dbms_security_procedures_unrestricted=apoc.\\\* \
        -t $NEO4J

# Wait for docker container to start.
tries=0
while true ; do
   echo "RETURN 'Cypher is Alive';" | docker exec -i "$CONTAINER" bin/cypher-shell -a localhost -u neo4j -p $PASSWORD

   if [ $? -eq 0 ] ; then
        echo "Docker instance is up ($tries tries)"
        break
   fi
   
   tries=$((tries+1))
   echo "Docker container not live yet ($tries tries)"

   if [ $tries -gt 30 ] ; then
        # Do not output the variables below, this will fail the start on purpose.
        echo "Docker is not coming up!  Something is wrong.  Check it out."
        exit 1
   fi

   sleep 1
done

echo NEO4J_URI=bolt://localhost
echo NEO4J_PASSWORD=$PASSWORD
echo STACK_NAME=$CONTAINER
echo RUN_ID=$RUN_ID
