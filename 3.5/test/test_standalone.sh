#!/bin/bash
#
# Testing script for causal clusters.  Adapted from GKE test script.
#
# PARAMETERS:  set NEO4J_URI, NEO4J_USERNAME, NEO4J_PASSWORD
# run this script
# Exit code of 0 means all good.  Exit code of 1 is tests failed.
set -x

if [ -z $NEO4J_URI ] || [ -z $NEO4J_USERNAME ] || [ -z $NEO4J_PASSWORD ] ; then
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

source ./test_common.sh

wait_for_live "$endpoint"

test="HTTPS is available, port 7443"
curl --insecure https://$host:7473/
if [ $? -eq 0 ] ; then
    succeed "$test"
else
    fail "$test"
fi

# Test utilities use bolt+routing, so we need to explicitly state just
# bolt for stand-alone tests.
BOLT="bolt://$host:7687"

runtest "Bolt is available"   "RETURN 'yes';" "$BOLT"
runtest "Basic read queries, encrypted connection"         "MATCH (n) RETURN COUNT(n);" "$BOLT"
runtest "Cluster accepts writes"                           'CREATE (t:TestNode) RETURN count(t);' "$BOLT"

modeQuery="call dbms.listConfig() yield name, value with name, value where name='dbms.mode' return value;"
test="DBMS mode is set to SINGLE"
dbms_mode=$(cypher "$modeQuery" "$BOLT" | grep SINGLE)
if [ $? -eq 0 ] ; then
    succeed "$test"
else
    fail "$test" "$dbms_mode"
fi

echo "All good; testing completed"
exit 0