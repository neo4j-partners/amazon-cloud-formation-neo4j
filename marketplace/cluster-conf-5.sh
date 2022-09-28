#!/bin/bash

readonly NODE_COUNT=$1
readonly READ_REPLICA_COUNT=$2
readonly LOAD_BALANCER_DNS_NAME=$3

extension_config() {
    echo Configuring extensions and security in neo4j.conf...
    sed -i s~#server.unmanaged_extension_classes=org.neo4j.examples.server.unmanaged=/examples/unmanaged~server.unmanaged_extension_classes=com.neo4j.bloom.server=/bloom,semantics.extension=/rdf~g /etc/neo4j/neo4j.conf
    sed -i s/#dbms.security.procedures.unrestricted=my.extensions.example,my.procedures.*/dbms.security.procedures.unrestricted=gds.*,apoc.*,bloom.*/g /etc/neo4j/neo4j.conf
    echo "dbms.security.http_auth_allowlist=/,/browser.*,/bloom.*" >>/etc/neo4j/neo4j.conf
    echo "dbms.security.procedures.allowlist=apoc.*,gds.*,bloom.*" >>/etc/neo4j/neo4j.conf

    echo "Configuring network in neo4j.conf..."
    sed -i 's/#server.default_listen_address=0.0.0.0/server.default_listen_address=0.0.0.0/g' /etc/neo4j/neo4j.conf
}

configure_clustering() {

    sed -i s/#server.default_advertised_address=localhost/server.default_advertised_address="${LOAD_BALANCER_DNS_NAME}"/g /etc/neo4j/neo4j.conf
    local -r privateIP="$(hostname -i | awk '{print $NF}')"
    sed -i s/#server.discovery.advertised_address=:5000/server.discovery.advertised_address="${privateIP}":5000/g /etc/neo4j/neo4j.conf
    sed -i s/#server.cluster.advertised_address=:6000/server.cluster.advertised_address="${privateIP}":6000/g /etc/neo4j/neo4j.conf
    sed -i s/#server.cluster.raft.advertised_address=:7000/server.cluster.raft.advertised_address="${privateIP}":7000/g /etc/neo4j/neo4j.conf
    sed -i s/#server.routing.advertised_address=:7688/server.routing.advertised_address="${privateIP}":7688/g /etc/neo4j/neo4j.conf
    sed -i s/#server.http.advertised_address=:7474/server.https.advertised_address="${privateIP}":7474/g /etc/neo4j/neo4j.conf
    sed -i s/#server.bolt.advertised_address=:7687/server.https.advertised_address="${privateIP}":7687/g /etc/neo4j/neo4j.conf

    sed -i s/#server.discovery.listen_address=:5000/server.discovery.listen_address="${privateIP}":5000/g /etc/neo4j/neo4j.conf
    sed -i s/#server.routing.listen_address=0.0.0.0:7688/server.routing.listen_address="${privateIP}":7688/g /etc/neo4j/neo4j.conf
    sed -i s/#server.cluster.listen_address=:6000/server.cluster.listen_address="${privateIP}":6000/g /etc/neo4j/neo4j.conf
    sed -i s/#server.cluster.raft.listen_address=:7000/server.cluster.raft.listen_address="${privateIP}":7000/g /etc/neo4j/neo4j.conf
    sed -i s/#server.bolt.listen_address=:7687/server.bolt.listen_address="${privateIP}":7687/g /etc/neo4j/neo4j.conf

    if [[ $NODE_COUNT == 1 ]]; then
        echo "Running on a single node."
        if [[ $READ_REPLICA_COUNT != 0 ]]; then
            echo "server.cluster.system_database_mode=PRIMARY" >>/etc/neo4j/neo4j.conf
            echo "server.cluster.initial_mode_constraint=PRIMARY" >>/etc/neo4j/neo4j.conf
            echo "dbms.cluster.num_primaries=1" >>/etc/neo4j/neo4j.conf
            echo "dbms.cluster.num_secondaries=${READ_REPLICA_COUNT}" >>/etc/neo4j/neo4j.conf
        fi
    else
        echo "Running on multiple nodes.  Configuring membership in neo4j.conf..."
        echo "server.cluster.system_database_mode=PRIMARY" >>/etc/neo4j/neo4j.conf
        echo "server.cluster.initial_mode_constraint=PRIMARY" >>/etc/neo4j/neo4j.conf
        echo "dbms.cluster.num_primaries=${NODE_COUNT}" >>/etc/neo4j/neo4j.conf
        region=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/.$//')
        instanceId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
        stackName=$(aws cloudformation describe-stack-resources --physical-resource-id $instanceId --query 'StackResources[0].StackName' --output text --region $region)
        coreMembers=$(aws autoscaling describe-auto-scaling-instances --region $region --output text --query "AutoScalingInstances[?contains(AutoScalingGroupName,'$stackName-Neo4jAutoScalingGroup')].[InstanceId]" | xargs -n1 -I {} aws ec2 describe-instances --instance-ids {} --region $region --query "Reservations[].Instances[].PrivateIpAddress" --output text --filter "Name=tag:aws:cloudformation:stack-name,Values=$stackName")
        coreMembers=$(echo ${coreMembers} | sed 's/ /:5000,/g')
        coreMembers=$(echo "${coreMembers}"):5000
        sed -i s/#dbms.cluster.discovery.endpoints=localhost:5000,localhost:5001,localhost:5002/dbms.cluster.discovery.endpoints=${coreMembers}/g /etc/neo4j/neo4j.conf
    fi
}
