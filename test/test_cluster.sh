#!/bin/bash
#
# Testing script for causal clusters.  Adapted from GKE test script.
#
# PARAMETERS:  set NEO4J_URI, NEO4J_USERNAME, NEO4J_PASSWORD, CORES, READ_REPLICAS
# run this script
# Exit code of 0 means all good.  Exit code of 1 is tests failed.
#
# Things tested:
# - Cluster forms, topology is as expected
# - Cluster accepts writes and reads
# - Data is replicated properly between cluster elements
# - APOC present on all nodes
set -x

if [ -z $NEO4J_URI ] || [ -z $NEO4J_USERNAME ] || [ -z $NEO4J_PASSWORD ] || \
   [ -z $CORES ] || [ -z $READ_REPLICAS ] ; then
    echo "Missing env vars"
    exit 1
fi

host=$NEO4J_URI
echo "HOST $host"
# This endpoint proves availability of the overall service
endpoint="https://$host:7473"
echo "ENDPOINT $endpoint"
# Mounted secret
NEO4J_SECRETS_PASSWORD=$NEO4J_PASSWORD
auth="neo4j:${NEO4J_SECRETS_PASSWORD}"
echo "AUTH $auth"
echo "CORES $CORES"
echo "RRs $READ_REPLICAS"

# When test resources are deployed cluster hasn't had a chance to form yet.
# This polls in a loop waiting for cluster to become available, and gives up/fails
# tests if it doesn't work within attempts.
attempt=0
attempts=100

while true; do
    attempt=$[$attempt + 1]
    curl --insecure -s -I $endpoint/ | grep "200 OK"
    if [ $? -eq 0 ] ; then
    echo "✔️ Neo4j is up at attempt $attempt"
    break
    fi

    if [ $attempt -ge "$attempts" ]; then
    echo "❌ REST API seems not to be coming up, giving up after $attempts attempts"
    exit 1
    fi

    echo "Sleeping; not up yet after $attempt attempts"
    sleep 5
done

# Pass index ID to get hostname for that pod.
function core_hostname {


    echo "{{ .Release.Name }}-neo4j-core-$1.{{ .Release.Name }}-neo4j.{{ .Release.Namespace }}.svc.cluster.local"
}

function replica_hostname {
    echo "{{ .Release.Name }}-replica-$1.{{ .Release.Name }}-readreplica.{{ .Release.Namespace }}.svc.cluster.local"
}

test_index=0

function succeed {
    echo "✔️  Test $test_index: $1"
    test_index=$[$test_index + 1]
}

function fail {
    echo "❌ Test $test_index: $1"
    echo "Additional information: " "$2"
    exit 1
}

function cypher {
    # Use routing driver by default, send query wherever.
    DEFAULT_ENDPOINT="bolt+routing://$host:7687"

    # If caller specified, use a specific endpoint to route a query to just one node.
    ENDPOINT=${2:-$DEFAULT_ENDPOINT}

    echo "$1" | cypher-shell --encryption true -u "$NEO4J_USERNAME" -a "$ENDPOINT" -p "$NEO4J_SECRETS_PASSWORD"
}

function get_bolt_endpoints_for_core {
    # Cypher query to find all cluster nodes with role $1 and return their bolt addresses
    query="call dbms.cluster.overview() yield role, addresses where role='LEADER' or role='FOLLOWER' WITH addresses UNWIND addresses as address WITH address where address =~ 'bolt:.*' return address ORDER BY address asc;"
    cypher "$query" | grep bolt | sed 's/"//g'
}

function get_bolt_endpoints_for_rr {
    # Cypher query to find all cluster nodes with role $1 and return their bolt addresses
    query="call dbms.cluster.overview() yield role, addresses where role='READ_REPLICA' WITH addresses UNWIND addresses as address WITH address where address =~ 'bolt:.*' return address ORDER BY address asc;"
    cypher "$query" | grep bolt | sed 's/"//g'
}

function runtest {
    # Use routing driver by default, send query wherever.
    DEFAULT_ENDPOINT="bolt+routing://$host:7687"

    # If caller specified, use a specific endpoint to route a query to just one node.
    ENDPOINT=${3:-$DEFAULT_ENDPOINT}

    echo "Running $1 against $ENDPOINT"
    output=$(cypher "$2" "$3")

    if [ $? -eq 0 ] ; then  
    succeed "$1"
    else
    echo "Last output -- $output"
    fail "$1" "$output"
    fi
}

test="HTTPS is available, port 7443"
curl --insecure https://$host:7473/
if [ $? -eq 0 ] ; then
    succeed "$test"
else
    fail "$test"
fi

echo "Basic topology upfront"
cypher "CALL dbms.cluster.overview();"

runtest "Bolt is available" "RETURN 'yes';"
runtest "Basic read queries, encrypted connection"         "MATCH (n) RETURN COUNT(n);"
runtest "Database is in clustered mode"                    "CALL dbms.cluster.overview();" 
runtest "Cluster accepts writes"                           'CREATE (t:TestNode) RETURN count(t);'

# Data from server on cluster topology.
topology=$(cypher "CALL dbms.cluster.overview();")
echo "TOPOLOGY $topology"

# LEADERS
leaders=$(echo $topology | grep -o LEADER | wc -l)
test="Cluster has 1 leader"
if [ $leaders -eq 1 ] ; then
    succeed "$test"
else
    fail "$test" "$leaders leaders"
fi

# FOLLOWERS
followers=$(echo $topology | grep -o FOLLOWER | wc -l)
test="Cluster has 1-CORES followers"
if [ $followers -eq $((CORES-1)) ] ; then
    succeed "$test"
else
    fail "$test" "$followers followers"
fi

# REPLICAS
read_replicas=$(echo $topology | grep -o READ_REPLICA | wc -l)
test="Cluster has $READ_REPLICAS read replicas"
if [ $read_replicas -eq $READ_REPLICAS ] ; then
    succeed "$test"
else
    fail "$test" "$read_replicas replicas"
fi

# Each core is individually up and configured.
for core_endpoint in $(get_bolt_endpoints_for_core); do
    echo "Core endpoint $core_endpoint"
    test="Core host $CORES -- $core_endpoint is available"
    runtest "$test" "MATCH (n) RETURN COUNT(n);" "$core_endpoint"

    test="Core host $CORES -- $core_endpoint has APOC installed correctly"
    runtest "$test" "RETURN apoc.version();" "$core_endpoint"
done

# Test for data replication.
runtest "Sample canary write" 'CREATE (c:Canary) RETURN count(c);'
echo "Sleeping a few seconds to permit replication"
sleep 5

# Check each core, count the canary writes. They should all agree.
for core_endpoint in $(get_bolt_endpoints_for_core); do
    test="Core endpoint $core_endpoint has the canary write"
    result=$(cypher "MATCH (c:Canary) WITH count(c) as x where x = 1 RETURN x;" "$core_endpoint")
    exit_code=$?
    if [ $exit_code -eq 0 ] ; then
    # Check that the data is there.
    found_results=$(echo "$result" | grep -o 1 | wc -l)

    if [ $found_results -eq 1 ] ; then
        succeed "$test"
    else 
        fail "$test" "Canary read did not return data -- $found_results found results from $result"
    fi
    else
    fail "$test" "Canary read failed to execute -- exit code $exit_code / RESULT -- $result"
    fi
done

for replica_endpoint  in $(get_bolt_endpoints_for_rr) ; do
    test="Read Replica $replica_endpoint has the canary write"
    result=$(cypher "MATCH (c:Canary) WITH count(c) as x where x = 1 RETURN x;" "$replica_endpoint")
    exit_code=$?
    if [ $exit_code -eq 0 ] ; then
        found_results=$(echo "$result" | grep -o 1 | wc -l)

        if [ $found_results -eq 1 ] ; then
        succeed "$test" "Canary read did not return data -- $found_results found results from $result"
        else
        fail "$test" 
        fi
    else
        fail "$test" "Canary read did not return data -- exit code $exit_code / RESULT -- $result"
    fi
done

echo "All good; testing completed"
exit 0
