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
    DEFAULT_ENDPOINT="neo4j://$host:7687"

    # If caller specified, use a specific endpoint to route a query to just one node.
    ENDPOINT=${2:-$DEFAULT_ENDPOINT}

    echo "$1" | cypher-shell --encryption false -u "$NEO4J_USERNAME" -a "$ENDPOINT" -p "$NEO4J_SECRETS_PASSWORD"
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
    DEFAULT_ENDPOINT="bolt://$host:7687"

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

function wait_for_live {
    # When test resources are deployed cluster hasn't had a chance to form yet.
    # This polls in a loop waiting for cluster to become available, and gives up/fails
    # tests if it doesn't work within attempts.
    attempt=0
    attempts=100

    while true; do
        attempt=$[$attempt + 1]
        curl --insecure -s -I "$1/" | grep "200 OK"
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
}
