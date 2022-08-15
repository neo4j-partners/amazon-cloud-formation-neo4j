#!/bin/bash
graphDatabaseVersion=$1
installGraphDataScience=$2
graphDataScienceLicenseKey=$3
installBloom=$4
bloomLicenseKey=$5
password=$6
nodeCount=$7
readReplicaCount=$8
loadBalancerDNSName=$9
stackName=${10}
region=${11}
loadBalancerDNSName=${12}

echo Adding neo4j yum repo...
rpm --import https://debian.neo4j.com/neotechnology.gpg.key
echo "
[neo4j]
name=Neo4j Yum Repo
baseurl=http://yum.neo4j.com/stable
enabled=1
gpgcheck=1" > /etc/yum.repos.d/neo4j.repo

echo Installing Graph Database...
export NEO4J_ACCEPT_LICENSE_AGREEMENT=yes
yum -y install neo4j-enterprise-${graphDatabaseVersion}
yum update -y aws-cfn-bootstrap
systemctl enable neo4j

echo Installing APOC...
mv /var/lib/neo4j/labs/apoc-*-core.jar /var/lib/neo4j/plugins

echo Configuring extensions and security in neo4j.conf...
sed -i s~#dbms.unmanaged_extension_classes=org.neo4j.examples.server.unmanaged=/examples/unmanaged~dbms.unmanaged_extension_classes=com.neo4j.bloom.server=/bloom,semantics.extension=/rdf~g /etc/neo4j/neo4j.conf
sed -i s/#dbms.security.procedures.unrestricted=my.extensions.example,my.procedures.*/dbms.security.procedures.unrestricted=gds.*,apoc.*,bloom.*/g /etc/neo4j/neo4j.conf
echo dbms.security.http_auth_allowlist=/,/browser.*,/bloom.* >> /etc/neo4j/neo4j.conf
echo dbms.security.procedures.allowlist=apoc.*,gds.*,bloom.* >> /etc/neo4j/neo4j.conf

echo Configuring network in neo4j.conf...
sed -i 's/#dbms.default_listen_address=0.0.0.0/dbms.default_listen_address=0.0.0.0/g' /etc/neo4j/neo4j.conf

privateIP=$(hostname -i | awk {'print $NF'})

function set_cluster_configs {
   sed -i s/#dbms.default_advertised_address=localhost/dbms.default_advertised_address=${privateIP}/g /etc/neo4j/neo4j.conf
   sed -i s/#causal_clustering.discovery_listen_address=:5000/causal_clustering.discovery_listen_address=${privateIP}:5000/g /etc/neo4j/neo4j.conf
   sed -i s/#causal_clustering.transaction_listen_address=:6000/causal_clustering.transaction_listen_address=${privateIP}:6000/g /etc/neo4j/neo4j.conf
   sed -i s/#causal_clustering.raft_listen_address=:7000/causal_clustering.raft_listen_address=${privateIP}:7000/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.connector.bolt.listen_address=:7687/dbms.connector.bolt.listen_address=${privateIP}:7687/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.connector.http.advertised_address=:7474/dbms.connector.http.advertised_address=${privateIP}:7474/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.connector.https.advertised_address=:7473/dbms.connector.https.advertised_address=${privateIP}:7473/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.routing.enabled=false/dbms.routing.enabled=true/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.routing.advertised_address=:7688/dbms.routing.advertised_address=${privateIP}:7688/g /etc/neo4j/neo4j.conf
   sed -i s/#dbms.routing.listen_address=0.0.0.0:7688/dbms.routing.listen_address=${privateIP}:7688/g /etc/neo4j/neo4j.conf
   echo dbms.routing.default_router=SERVER >> /etc/neo4j/neo4j.conf
}

if [[ $nodeCount == 1 ]]; then
  echo Running on a single node.

  if [[ $readReplicaCount == 0 ]]; then
     sed -i s/#dbms.default_advertised_address=localhost/dbms.default_advertised_address=${loadBalancerDNSName}/g /etc/neo4j/neo4j.conf
  else
     sed -i s/#dbms.mode=CORE/dbms.mode=SINGLE/g /etc/neo4j/neo4j.conf
     echo dbms.clustering.enable=true >> /etc/neo4j/neo4j.conf
     set_cluster_configs
  fi

else
  echo Running on multiple nodes.  Configuring membership in neo4j.conf...
  region=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/.$//')
  instanceId=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
  stackName=$(aws cloudformation describe-stack-resources --physical-resource-id $instanceId --query 'StackResources[0].StackName' --output text --region $region)
  coreMembers=$(aws autoscaling describe-auto-scaling-instances --region $region --output text --query "AutoScalingInstances[?contains(AutoScalingGroupName,'$stackName-Neo4jAutoScalingGroup')].[InstanceId]" | xargs -n1 -I {} aws ec2 describe-instances --instance-ids {} --region $region --query "Reservations[].Instances[].PrivateIpAddress" --output text --filter "Name=tag:aws:cloudformation:stack-name,Values=$stackName")
  coreMembers=$(echo $coreMembers | sed 's/ /:5000,/g')
  coreMembers=$(echo $coreMembers):5000
  sed -i s/#causal_clustering.initial_discovery_members=localhost:5000,localhost:5001,localhost:5002/causal_clustering.initial_discovery_members=${coreMembers}/g /etc/neo4j/neo4j.conf
  sed -i s/#dbms.mode=CORE/dbms.mode=CORE/g /etc/neo4j/neo4j.conf
  set_cluster_configs
fi

if [[ $installGraphDataScience == True && $nodeCount == 1 ]]; then
  echo Installing Graph Data Science...
  cp /var/lib/neo4j/products/neo4j-graph-data-science-*.jar /var/lib/neo4j/plugins
fi

if [[ $graphDataScienceLicenseKey != None ]]; then
  echo Writing GDS license key...
  mkdir -p /etc/neo4j/licenses
  echo $graphDataScienceLicenseKey > /etc/neo4j/licenses/neo4j-gds.license
  sed -i '$a gds.enterprise.license_file=/etc/neo4j/licenses/neo4j-gds.license' /etc/neo4j/neo4j.conf
fi

if [[ $installBloom == True ]]; then
  echo Installing Bloom...
  cp /var/lib/neo4j/products/bloom-plugin-*.jar /var/lib/neo4j/plugins
fi

if [[ $bloomLicenseKey != None ]]; then
  echo Writing Bloom license key...
  mkdir -p /etc/neo4j/licenses
  echo $bloomLicenseKey > /etc/neo4j/licenses/neo4j-bloom.license
  sed -i '$a neo4j.bloom.license_file=/etc/neo4j/licenses/neo4j-bloom.license' /etc/neo4j/neo4j.conf
fi

echo Starting Neo4j...
service neo4j start
neo4j-admin set-initial-password ${password}
/opt/aws/bin/cfn-signal -e $? --stack ${stackName} --resource Neo4jAutoScalingGroup --region ${region}
