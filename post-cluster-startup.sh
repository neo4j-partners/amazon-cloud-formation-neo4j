###########################################################
# Post-cluster startup
#
# We want to unbind each node and trash the graph.db
# directory.  This guarantees that every deployed cluster
# gets its own store ID for UDC reporting, and also that
# cluster formation metadata is guaranteed clean.
#
###########################################################
/bin/systemctl stop neo4j.service
/usr/bin/neo4j-admin unbind
/bin/rm -rf /var/lib/neo4j/data/databases/graph.db/
/bin/systemctl start neo4j.service

while true; do
    # Loop waiting for neo4j service to start.
    if curl -s -I http://localhost:7474 | grep "200 OK"; then
        echo "Neo4j is up; changing default password"
        # Tmp testing.
        adminPassword=testdrive

        # Change default password.
        curl -v -H "Content-Type: application/json" \
                -XPOST -d '{"password":"admin"}' \
                -u neo4j:neo4j \
                http://localhost:7474/user/neo4j/password
        echo "Done"
        break
    fi

    echo "Waiting for neo4j to come up"
    sleep 1
done
