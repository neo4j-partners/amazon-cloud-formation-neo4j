#!/bin/bash
# Automated script for grabbing logs from the relevant
# machines that are started in a test run.

# Hosts look like this:
4.3/azure/bin/exfiltrate-logs.sh
# neo4j-vm-core-0-tlpwuv5n4q5eo.westus.cloudapp.azure.com

# Usage:
# exfiltrate-logs.sh <prefix> <suffix> <region>
# exfiltrate-logs.sh neo4j tlpwuv5n4q5eo westus

echo My cluster prefix arg is $1
prefix=$1

echo My cluster suffix arg is $2
suffix=$2

region=${3:-eastus}
echo My region arg is $region

cores=3
read_replicas=0

USER=davidallen

exfil_logs () {
    mode=$1
    idx=$2
    LOGDIR=/var/log/neo4j

    host="$prefix-$mode-node-$idx-$suffix.$region.cloudapp.azure.com"

    dir="$prefix/$mode-$idx"
    mkdir -p "$prefix/${mode}-${idx}"

    copy_path () {
        tograb=$1
        echo scp -o "StrictHostKeyChecking no" "$USER@$host:$tograb" "$dir"
        scp -o "StrictHostKeyChecking no" "$USER@$host:$tograb" "$dir"
    }

    copy_path "$LOGDIR/*"
    copy_path "/etc/neo4j/neo4j.conf"
    ssh -o "StrictHostKeyChecking no" "$USER@$host" "journalctl -u neo4j -b" > "$dir/neo4j.log"
    ssh -o "StrictHostKeyChecking no" "$USER@$host" "sudo cat /root/post-deploy-setup.log" > "$dir/startup.log"
}

for i in `seq 0 $(expr $cores - 1)` ; do
    exfil_logs "core" $i
done

for i in `seq 0 $(expr $read_replicas - 1)` ; do
    exfil_logs "read-replica" $i
done

echo "Building profile"
find "$prefix" \
   -name debug.log \
   -exec egrep -n --with-filename \
   '(CLOUDMARK|Hazelcast|Raft|SenderService|Handshake|Cluster|MemberId|elect)' {} \; | sort > "$prefix/cluster-story.log"

echo "Logsizes"
find "$prefix" -name "debug.log" -exec wc -l {} \; > "$prefix/logsizes.txt"

echo "Finished log copy to directory $prefix"
