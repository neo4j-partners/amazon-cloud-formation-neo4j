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
