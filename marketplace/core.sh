#!/bin/bash
set -euo pipefail
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
s3AccessKeyId=${12}
s3SecretAccessKey=${13}


readonly scriptDir=$( cd "${0%/*}" && pwd -P )

configure_yum_repo() {
    echo "Adding neo4j yum repo..."
    rpm --import https://debian.neo4j.com/neotechnology.gpg.key
    cat <<EOF > /etc/yum.repos.d/neo4j.repo
[neo4j]
name=Neo4j Yum Repo
baseurl=http://yum.neo4j.com/stable
enabled=1
gpgcheck=1
EOF
}

install_neo4j_from_yum() {
    echo "Installing Graph Database..."
    export NEO4J_ACCEPT_LICENSE_AGREEMENT=yes
    yum -y install "neo4j-enterprise-${graphDatabaseVersion}"
    yum update -y aws-cfn-bootstrap
    systemctl enable neo4j
}

install_neo4j_from_s3() {
    export AWS_ACCESS_KEY_ID=${s3AccessKeyId}
    export AWS_SECRET_ACCESS_KEY=${s3SecretAccessKey}
    echo "Installing Graph Database..."
    export NEO4J_ACCEPT_LICENSE_AGREEMENT=yes
    aws s3 cp s3://clouders-neo4j5-rpm/cypher-shell-5.0.0-0.drop09.0.1.noarch.rpm .
    aws s3 cp s3://clouders-neo4j5-rpm/neo4j-enterprise-5.0.0-0.drop09.0.1.noarch.rpm .
    yum -y install cypher-shell-5.0.0-0.drop09.0.1.noarch.rpm neo4j-enterprise-5.0.0-0.drop09.0.1.noarch.rpm
    yum update -y aws-cfn-bootstrap
    systemctl enable neo4j

}

install_apoc_plugin() {
    echo "Installing APOC..."
    mv /var/lib/neo4j/labs/apoc-*-core.jar /var/lib/neo4j/plugins
}

select_cluster_config_from_version() {
    local -r db_version=$(echo "${graphDatabaseVersion}" | awk -F '.' '{print $1}')
    source "${scriptDir}/cluster-conf-${db_version}.sh" "${nodeCount}" "${readReplicaCount}" "${loadBalancerDNSName}"
}

configure_graph_data_science() {
  if [[ "${installGraphDataScience}" == True && "${nodeCount}" == 1 ]]; then
    echo "Installing Graph Data Science..."
    cp /var/lib/neo4j/products/neo4j-graph-data-science-*.jar /var/lib/neo4j/plugins
  fi

  if [[ $graphDataScienceLicenseKey != None ]]; then
    echo "Writing GDS license key..."
    mkdir -p /etc/neo4j/licenses
    echo "${graphDataScienceLicenseKey}" > /etc/neo4j/licenses/neo4j-gds.license
    sed -i '$a gds.enterprise.license_file=/etc/neo4j/licenses/neo4j-gds.license' /etc/neo4j/neo4j.conf
  fi

}

configure_bloom() {
  if [[ $installBloom == True ]]; then
    echo "Installing Bloom..."
    cp /var/lib/neo4j/products/bloom-plugin-*.jar /var/lib/neo4j/plugins
  fi

  if [[ $bloomLicenseKey != None ]]; then
    echo "Writing Bloom license key..."
    mkdir -p /etc/neo4j/licenses
    echo "${bloomLicenseKey}" > /etc/neo4j/licenses/neo4j-bloom.license
    sed -i '$a neo4j.bloom.license_file=/etc/neo4j/licenses/neo4j-bloom.license' /etc/neo4j/neo4j.conf
  fi
}

start_neo4j() {
  echo "Starting Neo4j..."
  service neo4j start
  neo4j-admin dbms set-initial-password "${password}"
  while [[ "$(curl -s -o /dev/null -m 3 -L -w '%{http_code}' http://localhost:7474 )" != "200" ]];
    do echo "Waiting for cluster to start"
    sleep 5
  done
  /opt/aws/bin/cfn-signal -e $? --stack "${stackName}" --resource Neo4j AutoScalingGroup --region "${region}"
}

#configure_yum_repo
#install_neo4j_from_yum
install_neo4j_from_s3
install_apoc_plugin
select_cluster_config_from_version
extension_config
configure_clustering
configure_graph_data_science
configure_bloom
start_neo4j
