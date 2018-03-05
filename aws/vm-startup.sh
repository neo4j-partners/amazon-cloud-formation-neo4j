#!/bin/bash
#
# This script starts at the launch of a VM, and handles final cluster coordination.
LOGFILE=/home/ubuntu/setup.log
echo `date` | tee -a $LOGFILE

/bin/systemctl stop neo4j.service 2>&1 | tee -a $LOGFILE
/usr/bin/neo4j-admin unbind 2>&1 | tee -a $LOGFILE
/bin/rm -rf /var/lib/neo4j/data/databases/graph.db/ 2>&1 | tee -a $LOGFILE
/bin/systemctl start neo4j.service 2>&1 | tee -a $LOGFILE

echo "Installing CloudFormation tools..." | tee -a $LOGFILE
curl https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz | tar xz -C aws-cfn-bootstrap-latest --strip-components 1
easy_install aws-cfn-bootstrap-latest 2>&1 | tee -a $LOGFILE

# Loop waiting for neo4j service to start.
while true; do
    if curl -s -I http://localhost:7474 | grep "200 OK"; then
        echo "Neo4j is up; changing default password" 2>&1 | tee -a $LOGFILE

        curl -v -H "Content-Type: application/json" \
                -XPOST -d '{"password":"$(ref.generated-password.password)"}' \
                -u neo4j:admin \
                http://localhost:7474/user/neo4j/password \
                2>&1 | tee -a $LOGFILE
        echo "Password reset, signaling success" 2>&1 | tee -a $LOGFILE

        # SIGNAL TBD
        break
    fi

    echo "Waiting for neo4j to come up" 2>&1 | tee -a $LOGFILE
    sleep 1
done
