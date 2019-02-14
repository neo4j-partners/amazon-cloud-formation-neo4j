#!/bin/bash
#
# This startup script replaces the normal neo4j startup process for cloud environments.
# The purpose of the script is to gather machine IP and other settings, such as key/value
# pairs from the instance tags, and use that to configure neo4j.conf.
#
# In this way, neo4j does not need to know ahead of time what it's IP will be, and
# can be controlled by tags put on the instance.
######################################################################################
echo "pre-neo4j.sh: Fetching AWS instance metadata"

# Documentation: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-metadata.html
export API=http://169.254.169.254/latest/
export MAC_ADDR=$(curl --silent $API/meta-data/network/interfaces/macs/)
export INTERNAL_IP_ADDR=$(curl --silent $API/meta-data/network/interfaces/macs/$MAC_ADDR/local-ipv4s)
export EXTERNAL_IP_ADDR=$(curl -f --silent $API/meta-data/network/interfaces/macs/$MAC_ADDR/public-ipv4s)

if [ $? -ne 0 || "$EXTERNAL_IP_ADDR" = "" ] ; then
   echo "pre-neo4j.sh: Advertising internal IP since instance lacks external public IP"
   export EXTERNAL_IP_ADDR=$INTERNAL_IP_ADDR
fi

export INSTANCE_ID=$(curl --silent $API/meta-data/instance-id)
export AVAILABILITY_ZONE=$(curl --silent $API/meta-data/placement/availability-zone)
export REGION=`curl -s http://169.254.169.254/latest/dynamic/instance-identity/document|grep region|awk -F\" '{print $4}'`

get_instance_tags () {
    instance_id=$(curl --silent $API/meta-data/instance-id)
    echo $(aws ec2 describe-tags --filters "Name=resource-id,Values=$instance_id" --region=${REGION})
}

get_ami_tags () {
    ami_id=$(curl --silent $API/meta-data/ami-id)
    echo $(aws ec2 describe-tags --filters "Name=resource-id,Values=$ami_id" --region=${REGION})
}

tags_to_env () {
    tags=$1
    # Go through JSON keys, setting env vars in all lowercase.
    # so instance tag "Foo_Bar": 5 becomes export foo_bar=5
    for key in $(echo $tags | /usr/bin/jq -r ".[][].Key"); do
        value=$(echo $tags | /usr/bin/jq -r ".[][] | select(.Key==\"$key\") | .Value")
        key=$(echo $key | /usr/bin/tr '-' '_' | /usr/bin/tr '[:upper:]' '[:lower:]')
        echo "Configuring environment $key=$value"
        export $key="$value"
    done
}

# Fetch AMI tags and instance tags, and translate those JSON
# tags into a set of environment variables, declared within this shell.
ami_tags=$(get_ami_tags)
instance_tags=$(get_instance_tags)

tags_to_env "$ami_tags"
tags_to_env "$instance_tags"

# At this point all env vars are in place, we only need to fill out those missing
# with defaults provided below.
# Defaults are provided under the assumption that we're running a single node enterprise
# deploy.

# HTTPS
echo "dbms_connector_https_enabled" "${dbms_connector_https_enabled:=true}"
echo "dbms_connector_https_listen_address" "${dbms_connector_https_listen_address:=0.0.0.0:7473}"

# HTTP
echo "dbms_connector_http_enabled" "${dbms_connector_http_enabled:=true}"
echo "dbms_connector_http_listen_address" "${dbms_connector_http_listen_address:=0.0.0.0:7474}"

# BOLT
echo "dbms_connector_bolt_enabled" "${dbms_connector_bolt_enabled:=true}"
echo "dbms_connector_bolt_listen_address" "${dbms_connector_bolt_listen_address:=0.0.0.0:7687}"
echo "dbms_connector_bolt_tls_level" "${dbms_connector_bolt_tls_level:=REQUIRED}"

# Backup
echo "dbms_backup_enabled" "${dbms_backup_enabled:=true}"
echo "dbms_backup_address" "${dbms_backup_address:=localhost:6362}"

# Causal Clustering
echo "causal_clustering_discovery_type" "${causal_clustering_discovery_type:=LIST}"
echo "causal_clustering_initial_discovery_members" "${causal_clustering_initial_discovery_members:=localhost:5000}"
echo "causal_clustering_minimum_core_cluster_size_at_formation" "${causal_clustering_minimum_core_cluster_size_at_formation:=3}"
echo "causal_clustering_minimum_core_cluster_size_at_runtime" "${causal_clustering_minimum_core_cluster_size_at_runtime:=3}"

echo "dbms_connectors_default_listen_address" "${dbms_connectors_default_listen_address:=0.0.0.0}"
echo "dbms_mode" "${dbms_mode:=SINGLE}"
echo "causal_clustering_discovery_listen_address" "${causal_clustering_discovery_listen_address:=0.0.0.0:5000}"

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
    dbms_connector_http_enabled \
    dbms_connector_http_listen_address \
    dbms_connector_bolt_enabled \
    dbms_connector_bolt_listen_address \
    dbms_connector_bolt_tls_level \
    dbms_backup_enabled \
    dbms_backup_address \
    causal_clustering_discovery_type \
    causal_clustering_initial_discovery_members \
    causal_clustering_minimum_core_cluster_size_at_formation \
    causal_clustering_minimum_core_cluster_size_at_runtime \
    causal_clustering_expected_core_cluster_size \
    dbms_connectors_default_listen_address \
    dbms_mode \
    causal_clustering_discovery_listen_address \
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

echo "pre-neo4j.sh: Starting neo4j console..."

# Check to see if enterprise is installed.
dpkg -l | grep neo4j-enterprise
if [ "$?" -ne 0 ] && [ -f /etc/neo4j/password-reset.log ]; then
    # Only reset password for community, which is deployed as single AMI w/o
    # CloudFormation templating. In the enterprise case, cloudformation handles
    # the password reset bit.
    #
    # Also, only do this if the password reset log exists.  This ensures that
    # during a packer build, the password doesn't get reset to the packer instance ID,
    # and only happens on first user startup.
    echo "Startup: checking to see if password needs to be reset"
    exec /etc/neo4j/reset-password-aws.sh & 
fi

# This is the same command sysctl's service would have executed.
/usr/share/neo4j/bin/neo4j console
