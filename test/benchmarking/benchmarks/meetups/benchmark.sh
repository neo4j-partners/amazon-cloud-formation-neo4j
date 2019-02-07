#!/bin/bash

echo "====================================================" 
echo "== MEETUP BENCHMARK"
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
SEGMENT_FILE=segment-files-subset.txt

TAG=$(head -c 3 /dev/urandom | md5 | head -c 5)

STARTTIME=$(date +%s)

# We will add the exit code of all sub-processes
# If they're all zero, we exit good.  Otherwise
# we exit non-zero error.
OVERALL_EXIT_CODE=0

echo "Index phase" 
START_INDEX=$(date +%s)
cat 01-index.cypher | cypher-shell -a $NEO4J_URI
OVERALL_EXIT_CODE=$(($OVERALL_EXIT_CODE + $?))
END_INDEX=$(date +%s)
ELAPSED_INDEX=$(($END_INDEX - $START_INDEX))

echo "Load phase" 
START_LOAD=$(date +%s)
./load-all.sh $SEGMENT_FILE
OVERALL_EXIT_CODE=$(($OVERALL_EXIT_CODE + $?))
END_LOAD=$(date +%s)
ELAPSED_LOAD=$(($END_LOAD - $START_LOAD))

echo "Cities phase" 
START_CITIES=$(date +%s)
cat 02b-load-world-cities.cypher | cypher-shell -a $NEO4J_URI
OVERALL_EXIT_CODE=$(($OVERALL_EXIT_CODE + $?))
END_CITIES=$(date +%s)
ELAPSED_CITIES=$(($END_CITIES - $START_CITIES))

echo "Link groups phase"
START_LINK=$(date +%s)
cat 03a-link-groups-to-countries.cypher | cypher-shell -a $NEO4J_URI
OVERALL_EXIT_CODE=$(($OVERALL_EXIT_CODE + $?))
echo "Link venues phase" 
cat 03b-link-venues-to-cities.cypher | cypher-shell -a $NEO4J_URI 
OVERALL_EXIT_CODE=$(($OVERALL_EXIT_CODE + $?))
END_LINK=$(date +%s)
ELAPSED_LINK=$(($END_LINK - $START_LINK))

queries=5
runtimes=10
echo BENCHMARK_SETTING_TIME_RESOLUTION=seconds
echo BENCHMARK_SETTING_QUERIES=$queries
echo BENCHMARK_SETTING_RUNTIMES=$runtimes
echo BENCHMARK_SETTING_SEGMENTS=`wc -l "$SEGMENT_FILE" | awk '{print $1}'`
echo BENCHMARK_SETTING_TAG=$TAG
echo BENCHMARK_SETTING_NEO4J_URI=$NEO4J_URI

for q in `seq 1 $queries` ; do 
    echo "Queryload $q phase"
    for i in `seq 1 $runtimes` ; do 
        cat read-queries/q$q >> queryload-$TAG-$q.cypher
    done

    cat queryload-$TAG-$q.cypher | cypher-shell -a $NEO4J_URI
    OVERALL_EXIT_CODE=$(($OVERALL_EXIT_CODE + $?))
done
ENDTIME=$(date +%s)
ELAPSED=$(($ENDTIME - $STARTTIME))
echo "BENCHMARK ELAPSED TIME IN SECONDS: " $ELAPSED

rm -f queryload-$TAG-*.cypher
echo "Done"

echo "====================================================" 
echo "== BENCHMARK $TAG $1"
echo "== FINISH: " $(date)
echo "===================================================="
echo "Benchmark $TAG complete with $ELAPSED elapsed"

echo "BENCHMARK_ELAPSED=$ELAPSED"
echo "BENCHMARK_LINK=$ELAPSED_LINK"
echo "BENCHMARK_LOAD=$ELAPSED_LOAD"
echo "BENCHMARK_CITIES=$ELAPSED_CITIES"
echo "BENCHMARK_INDEX=$ELAPSED_INDEX"
exit $OVERALL_EXIT_CODE