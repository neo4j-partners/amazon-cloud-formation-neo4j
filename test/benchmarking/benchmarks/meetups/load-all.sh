#!/bin/bash

if [ -z $NEO4J_URI ] ; then
   "Please set NEO4J_URI"
   exit 1
fi

if [ -z $1 ]; then
   segments=segment-files.txt
else
   segments=$1
fi

cat 01-index.cypher | cypher-shell -a $NEO4J_URI

for f in $(cat $segments) ; do
 export file=$f
 echo "Loading $file"
 cat 02-load.cypher | envsubst | cypher-shell -a $NEO4J_URI

 if [ $? -ne 0 ] ; then
    exit 1
 fi
done
