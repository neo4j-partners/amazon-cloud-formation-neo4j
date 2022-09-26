#!/bin/bash

readonly NODE_COUNT=$1
readonly READ_REPLICA_COUNT=$2
readonly LOAD_BALANCER_DNS_NAME=$3


extension_config() {
    echo Configuring extensions and security in neo4j.conf...
    sed -i s~#dbms.unmanaged_extension_classes=org.neo4j.examples.server.unmanaged=/examples/unmanaged~dbms.unmanaged_extension_classes=com.neo4j.bloom.server=/bloom,semantics.extension=/rdf~g /etc/neo4j/neo4j.conf
    sed -i s/#dbms.security.procedures.unrestricted=my.extensions.example,my.procedures.*/dbms.security.procedures.unrestricted=gds.*,apoc.*,bloom.*/g /etc/neo4j/neo4j.conf
    echo "dbms.security.http_auth_allowlist=/,/browser.*,/bloom.*" >> /etc/neo4j/neo4j.conf
    echo "dbms.security.procedures.allowlist=apoc.*,gds.*,bloom.*" >> /etc/neo4j/neo4j.conf

    echo "Configuring network in neo4j.conf..."
    sed -i 's/#dbms.default_listen_address=0.0.0.0/dbms.default_listen_address=0.0.0.0/g' /etc/neo4j/neo4j.conf
}


set_cluster_configs() {
   local -r privateIP="$(hostname -i | awk '{print $NF}')"
   sed -i s/#dbms.default_advertised_address=localhost/dbms.default_advertised_address="${privateIP}"/g /etc/neo4j/neo4j.conf
   sed -i s/#causal_clustering.discovery_listen_address=:5000/causal_clustering.discovery_listen_address="${privateIP}":5000/g /etc/neo4j/neo4j.conf
   sed -i s/#causal_clustering.transaction_listen_address=:6000/causal_clustering.transaction_listen_address="${privateIP}":6000/g /etc/neo4j/neo4j.conf
   sed -i s/#causal_clustering.raft_listen_address=:7000/causal_clustering.raft_listen_address="${privateIP}":7000/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.connector.bolt.listen_address=:7687/dbms.connector.bolt.listen_address="${privateIP}":7687/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.connector.http.advertised_address=:7474/dbms.connector.http.advertised_address="${privateIP}":7474/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.connector.https.advertised_address=:7473/dbms.connector.https.advertised_address="${privateIP}":7473/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.routing.enabled=false/dbms.routing.enabled=true/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.routing.advertised_address=:7688/dbms.routing.advertised_address="${privateIP}":7688/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.routing.listen_address=0.0.0.0:7688/dbms.routing.listen_address="${privateIP}":7688/g /etc/neo4j/neo4j.conf
   echo "dbms.routing.default_router=SERVER" >> /etc/neo4j/neo4j.conf
}

configure_clustering() {
  if [[ $NODE_COUNT == 1 ]]; then
    echo "Running on a single node."

    if [[ $READ_REPLICA_COUNT == 0 ]]; then
       sed -i s/#dbms.default_advertised_address=localhost/dbms.default_advertised_address="${LOAD_BALANCER_DNS_NAME}"/g /etc/neo4j/neo4j.conf
    else
       sed -i s/#dbms.mode=CORE/dbms.mode=SINGLE/g /etc/neo4j/neo4j.conf
       echo "dbms.clustering.enable=true" >> /etc/neo4j/neo4j.conf
       set_cluster_configs
    fi

  else
    echo "Running on multiple nodes.  Configuring membership in neo4j.conf..."
    region=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/.$//')
    instanceId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    stackName=$(aws cloudformation describe-stack-resources --physical-resource-id $instanceId --query 'StackResources[0].StackName' --output text --region $region)
    coreMembers=$(aws autoscaling describe-auto-scaling-instances --region $region --output text --query "AutoScalingInstances[?contains(AutoScalingGroupName,'$stackName-Neo4jAutoScalingGroup')].[InstanceId]" | xargs -n1 -I {} aws ec2 describe-instances --instance-ids {} --region $region --query "Reservations[].Instances[].PrivateIpAddress" --output text --filter "Name=tag:aws:cloudformation:stack-name,Values=$stackName")
    coreMembers=$(echo "${coreMembers}" | sed 's/ /:5000,/g')
    coreMembers=$(echo "${coreMembers}"):5000
    sed -i s/#causal_clustering.initial_discovery_members=localhost:5000,localhost:5001,localhost:5002/causal_clustering.initial_discovery_members=${coreMembers}/g /etc/neo4j/neo4j.conf
    sed -i s/#dbms.mode=CORE/dbms.mode=CORE/g /etc/neo4j/neo4j.conf
    set_cluster_configs
  fi
}

