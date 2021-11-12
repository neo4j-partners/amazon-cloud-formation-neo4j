#!/bin/bash
#
# This startup script replaces the normal neo4j startup process for cloud environments.
# The purpose of the script is to gather machine IP and other settings, such as key/value
# pairs from the instance tags, and use that to configure neo4j.conf.
#
# In this way, neo4j does not need to know ahead of time what it's IP will be, and
# can be controlled by tags put on the instance.
######################################################################################
echo "pre-neo4j.sh: Fetching Azure instance metadata"

# Azure Instance Metadata
# Documentation: https://docs.microsoft.com/en-us/azure/virtual-machines/windows/instance-metadata-service
export NEO4J_HOME=/var/lib/neo4j
export API=http://169.254.169.254/metadata
export VERSION=api-version=2017-08-01
export HEADERS="-H Metadata:true"
export INTERNAL_IP_ADDR=$(curl $HEADERS --silent $API/instance/network/interface/0/ipv4/ipAddress/0/privateIpAddress?$VERSION\&format=text)
export EXTERNAL_IP_ADDR=$(curl -f $HEADERS --silent $API/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?$VERSION\&format=text)

if [ $? -ne 0 ] || [ "$EXTERNAL_IP_ADDR" = "" ] ; then
   echo "pre-neo4j.sh: Advertising internal IP since instance lacks external public IP"
   export EXTERNAL_IP_ADDR=$INTERNAL_IP_ADDR
fi

export INSTANCE_ID=$(curl $HEADERS --silent $API/instance?$VERSION | jq -r '.compute.vmId')

get_instance_tags () {
    joinedTags=$(curl $HEADERS --silent $API/instance?$VERSION | jq -r '.compute.tags')
    # Tags come like this:
    # tag1:value1;tag2:value2
    # So we need to split/transform into:
    # tag1=value1
    # tag2=value2
    # Which will make it easy to re-export them.
    echo "$joinedTags" | perl -e '
        use strict;

        my $line = <STDIN>;
        chomp($line);
        my @parts = split(/;/, $line);

        foreach my $part (@parts) {
            # Only first, not global, in case value contains :
            # as in default_advertised_address::0.0.0.0
            $part =~ s/:/=/;
            print $part,"\n";
        }
    '
}

tags_to_env () {
    tags=$1
    # Go through JSON keys, setting env vars in all lowercase.
    # so instance tag "Foo_Bar": 5 becomes export foo_bar=5
    for kvPair in $tags; do
        export $kvPair
    done
}

# Fetch instance tags, transform them into X=Y pairs, and then
# export those pairs into current shell environment.
instance_tags=$(get_instance_tags)
tags_to_env "$instance_tags"

running_as_root () {
    test "$(id -u)" = "0"
}

create_dir_if_necessary () {
    for directory in "$@"; do
        if [ ! -d "${directory}" ]; then
            mkdir -p "${directory}"
            chown "${userid}":"${groupid}" "${directory}"
            chown "${userid}":"${groupid}" "${certificates_dir}"
        fi
    done
}

create_dir_if_necessary

generate_self_signed_certificates () {
    local ip_address="$EXTERNAL_IP_ADDR"
    local dns_address="${SSL_DNS:-0.0.0.0}"
    local certificates_dir="${NEO4J_HOME}/certificates"
    if [ -d /ssl ]; then
        certificates_dir="/ssl"
    fi

    create_dir_if_necessary "${certificates_dir}/bolt/trusted" \
        "${certificates_dir}/bolt/revoked" \
        "${certificates_dir}/https/trusted" \
        "${certificates_dir}/https/revoked" \
        "${certificates_dir}/cluster/trusted" \
        "${certificates_dir}/cluster/revoked"
    local openssl_config="
[ req ]
prompt = no
distinguished_name = req_distinguished_name
x509_extensions = san_self_signed
[ req_distinguished_name ]
CN=$EXTERNAL_IP_ADDR
[ san_self_signed ]
subjectAltName = IP:$EXTERNAL_IP_ADDR,DNS:${dns_address}
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = CA:false
keyUsage = nonRepudiation, digitalSignature, keyEncipherment, dataEncipherment, keyCertSign, cRLSign
extendedKeyUsage = serverAuth, clientAuth, timeStamping
"

    local private_key="${certificates_dir}/bolt/private.key"
    local public_cert="${certificates_dir}/bolt/public.crt"

    openssl req \
      -newkey rsa:2048 -nodes \
      -keyout "${private_key}" \
      -x509 -sha256 -days 800 \
      -config <(echo "${openssl_config}") \
      -out "${public_cert}"

chown "${userid}":"${groupid}" "${private_key}"
    if running_as_root; then
        chmod 444 "${private_key}"
    else
        chmod 440 "${private_key}"
    fi
    chown "${userid}":"${groupid}" "${public_cert}"
    chmod 444 "${public_cert}"

    cp "${private_key}" "${certificates_dir}/https/"
    cp "${public_cert}" "${certificates_dir}/https/"
    cp "${private_key}" "${certificates_dir}/cluster/"
    cp "${public_cert}" "${certificates_dir}/cluster/"
    cp "${public_cert}" "${certificates_dir}/cluster/trusted/"
}

if [ ! -f "$NEO4J_HOME/certificates/https/private.key" ]; then
    echo "Certificates does not exist, generating certificates..."
    generate_self_signed_certificates
fi

# At this point all env vars are in place, we only need to fill out those missing
# with defaults provided below.
# Defaults are provided under the assumption that we're running a single node enterprise
# deploy.

# HTTPS
echo "dbms_connector_https_enabled" "${dbms_connector_https_enabled:=true}"
echo "dbms_connector_https_advertised_address" "${dbms_connector_https_advertised_address:=:7473}"
echo "dbms_connector_https_listen_address" "${dbms_connector_https_listen_address:=0.0.0.0:7473}"
echo "dbms_ssl_policy_https_enabled" "${dbms_ssl_policy_https_enabled:=true}"
echo "dbms_ssl_policy_https_base_directory" "${dbms_ssl_policy_https_base_directory:=/var/lib/neo4j/certificates/https}"
echo "$dbms_ssl_policy_https_client_auth" "${dbms_ssl_policy_https_client_auth:=NONE}"
echo "$dbms_ssl_policy_https_trust_all" "${dbms_ssl_policy_https_trust_all:=true}"

# HTTP
echo "dbms_connector_http_enabled" "${dbms_connector_http_enabled:=true}"
echo "dbms_connector_http_advertised_address" "${dbms_connector_http_advertised_address:=:7474}"
echo "dbms_connector_http_listen_address" "${dbms_connector_http_listen_address:=0.0.0.0:7474}"

# BOLT
echo "dbms_connector_bolt_enabled" "${dbms_connector_bolt_enabled:=true}"
echo "dbms_connector_bolt_advertised_address" "${dbms_connector_bolt_advertised_address:=:7687}"
echo "dbms_connector_bolt_tls_level" "${dbms_connector_bolt_tls_level:=OPTIONAL}"
echo "dbms_default_advertised_address" "${dbms_default_advertised_address:=$INTERNAL_IP_ADDR}"
echo "dbms_ssl_policy_bolt_enabled" "${dbms_ssl_policy_bolt_enabled:=true}"
echo "dbms_ssl_policy_bolt_base_directory" "${dbms_ssl_policy_bolt_base_directory:=/var/lib/neo4j/certificates/bolt}"
echo "$dbms_ssl_policy_bolt_client_auth" "${dbms_ssl_policy_bolt_client_auth:=NONE}"

# Backup
echo "dbms_backup_enabled" "${dbms_backup_enabled:=true}"
echo "dbms_backup_address" "${dbms_backup_address:=localhost:6362}"

# Causal Clustering
echo "causal_clustering_discovery_type""${causal_clustering_discovery_type:=LIST}"
echo "causal_clustering_initial_discovery_members" "${causal_clustering_initial_discovery_members:=neo4j-vm-core-0:5000,neo4j-vm-core-1:5000,neo4j-vm-core-2:5000}"
echo "causal_clustering_minimum_core_cluster_size_at_formation" "${causal_clustering_minimum_core_cluster_size_at_formation:=3}"
echo "causal_clustering_minimum_core_cluster_size_at_runtime" "${causal_clustering_minimum_core_cluster_size_at_runtime:=3}"
echo "causal_clustering_discovery_advertised_address" "${causal_clustering_discovery_advertised_address:=$HOSTNAME:5000}"
echo "dbms_default_listen_address" "${dbms_default_listen_address:=$INTERNAL_IP_ADDR}"
echo "dbms_ssl_policy_cluster_enabled" "${dbms_ssl_policy_cluster_enabled:=true}"
echo "dbms_ssl_policy_cluster_trust_all" "${dbms_ssl_policy_cluster_trust_all:=true}"
echo "dbms_ssl_policy_cluster_base_directory" "${dbms_ssl_policy_cluster_base_directory:=/var/lib/neo4j/certificates/cluster}"
echo "dbms_mode" "${dbms_mode:=SINGLE}"

# Logging
echo "dbms_logs_http_enabled" "${dbms_logs_http_enabled:=false}"
echo "dbms_logs_gc_enabled" "${dbms_logs_gc_enabled:=false}"
echo "dbms_logs_security_level" "${dbms_logs_security_level:=INFO}"

# Misc
echo "dbms_security_allow_csv_import_from_file_urls" "${dbms_security_allow_csv_import_from_file_urls:=true}"

# Neo4j mode.
# Different template gets substituted depending on if we're
# in standalone or cluster mode, because the CC attributes need
# to be commented out in the conf file.
echo "neo4j_mode" "${neo4j_mode:=SINGLE}"

export dbms_connector_https_enabled \
    dbms_connector_https_listen_address \
    dbms_ssl_policy_https_enabled \
    dbms_connector_https_advertised_address \
    dbms_ssl_policy_https_base_directory \
    dbms_ssl_policy_https_trust_all \
    dbms_ssl_policy_https_client_auth \
    dbms_connector_http_enabled \
    dbms_connector_http_listen_address \
    dbms_connector_http_advertised_address \
    dbms_connector_bolt_enabled \
    dbms_connector_bolt_advertised_address \
    dbms_ssl_policy_bolt_client_auth \
    dbms_ssl_policy_bolt_enabled \
    dbms_connector_bolt_tls_level \
    dbms_ssl_policy_bolt_trust_all \
    dbms_ssl_policy_bolt_base_directory \
    dbms_backup_enabled \
    dbms_backup_address \
    dbms_ssl_policy_backup_trust_all \
    causal_clustering_discovery_type \
    causal_clustering_initial_discovery_members \
    causal_clustering_minimum_core_cluster_size_at_formation \
    causal_clustering_minimum_core_cluster_size_at_runtime \
    causal_clustering_expected_core_cluster_size \
    dbms_ssl_policy_cluster_enabled \
    dbms_ssl_policy_cluster_base_directory \
    dbms_ssl_policy_cluster_trust_all \
    dbms_default_advertised_address \
    dbms_default_listen_address \
    dbms_mode \
    causal_clustering_discovery_advertised_address \
    dbms_logs_http_enabled \
    dbms_logs_gc_enabled \
    dbms_logs_security_level \
    dbms_security_allow_csv_import_from_file_urls

echo "pre-neo4j.sh: External IP $EXTERNAL_IP_ADDR"
echo "pre-neo4j.sh internal IP $INTERNAL_IP_ADDR"
echo "pre-neo4j.sh environment for configuration setup"
env

echo "neo4j_mode $neo4j_mode"
envsubst < /etc/neo4j/neo4j.template > /etc/neo4j/neo4j.conf
cp -rf /etc/neo4j/neo4j.conf /var/lib/neo4j/conf/neo4j.conf

echo "pre-neo4j.sh: Starting neo4j console..."

# This is the same command sysctl's service would have executed.
exec /usr/share/neo4j/bin/neo4j console