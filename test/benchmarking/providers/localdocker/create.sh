#!/bin/bash

export RUN_ID=$(head -c 1024 /dev/urandom | md5)
PASSWORD=admin
CWD=`pwd`
NEO4J=neo4j:3.5.2-enterprise
PAGE_CACHE=1G
INITIAL_HEAP=2G
MAX_HEAP=4G
CONTAINER=benchmark-neo4j-$RUN_ID

APOC=https://github.com/neo4j-contrib/neo4j-apoc-procedures/releases/download/3.5.0.1/apoc-3.5.0.1-all.jar
mkdir /tmp/$CONTAINER && wget -P /tmp/$CONTAINER $APOC

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

echo NEO4J_IP=localhost
echo NEO4J_PASSWORD=$PASSWORD
echo STACK_NAME=$CONTAINER
echo RUN_ID=$RUN_ID
