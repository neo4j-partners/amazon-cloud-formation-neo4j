#!/bin/bash

STRESS_TEST=../../../../stress-testing/src/

TAG=$(head -c 3 /dev/urandom | md5 | head -c 5)

echo "===================================================="
echo "== WRITEFAST BENCHMARK $TAG $1"
echo "== START: " $(date)
echo "===================================================="

if [ -z $2 ] ; then 
   echo "Usage: ./benchmark.sh bolt+routing://host:7687 Neo4jPassword"
   exit 1
fi

if [ -z $1 ] ; then
   echo  "Usage: ./benchmark.sh bolt+routing://host:7687 Neo4jPassword"
   exit 1
fi

export NEO4J_URI=$1
export NEO4J_PASSWORD=$2
export NEO4J_USERNAME=neo4j

# 100k writes, 25 at a time.
export CONCURRENCY=25
export ROUNDS=100000

# Configuration for how to do the writes, with
# which frequency.
workload=`pwd`/workload.json

cd $STRESS_TEST && node stress.js \
    --concurrency $CONCURRENCY \
    --n $ROUNDS \
    --checkpoint 1000 \
    --workload "$workload"
RESULT_CODE=$?

echo BENCHMARK_SETTING_TIME_RESOLUTION=milliseconds
echo BENCHMARK_SETTING_NEO4J_URI=$NEO4J_URI
echo BENCHMARK_SETTING_CONCURRENCY=$CONCURRENCY
echo BENCHMARK_SETTING_ROUNDS=$ROUNDS

echo "Stress Test Benchmark $TAG finshed"
echo "===================================================="
echo "== WRITEFAST BENCHMARK $TAG $1"
echo "== END: " $(date)
echo "===================================================="
exit $RESULT_CODE