#!/bin/bash
#
# Google Compute Metadata API Docs:
# https://cloud.google.com/compute/docs/storing-retrieving-metadata
#
# Get our external IP from the google metadata catalog.
echo "pre-neo4j.sh: Fetching GCP instance metadata"

export INSTANCE_API=http://metadata.google.internal/computeMetadata/v1/instance

# Settings and defaults
# Bash associative array docs: https://www.artificialworlds.net/blog/2012/10/17/bash-associative-array-examples/
# Idea here is to permit customization of neo4j.conf attributes via instance metadata registered with
# google.
declare -A NEO4J_SETTINGS

# HTTPS
echo "dbms_connector_https_enabled" "${dbms_connector_https_enabled:=false}"
echo "dbms_connector_https_advertised_address" "${dbms_connector_https_advertised_address:=0.0.0.0:7473}"

# HTTP
echo "dbms_connector_http_enabled" "${dbms_connector_http_enabled:=true}"
echo "dbms_connector_http_advertised_address" "${dbms_connector_http_advertised_address:=0.0.0.0:7474}"

# BOLT
echo "dbms_connector_bolt_enabled" "${dbms_connector_bolt_enabled:=true}"
echo "dbms_connector_bolt_advertised_address" "${dbms_connector_bolt_advertised_address:=0.0.0.0:7687}"
echo "dbms_connector_bolt_tls_level" "${dbms_connector_bolt_tls_level:=DISABLED}"
echo "dbms_default_advertised_address" "${dbms_default_advertised_address:=0.0.0.0}"

# Backup
#echo "dbms_backup_enabled" "${dbms_backup_enabled:=true}"
#echo "dbms_backup_address" "${dbms_backup_address:=localhost:6362}"

# Causal Clustering
echo "causal_clustering_discovery_type""${causal_clustering_discovery_type:=LIST}"
echo "causal_clustering_initial_discovery_members" "${causal_clustering_initial_discovery_members:=localhost:5000}"
echo "causal_clustering_minimum_core_cluster_size_at_formation" "${causal_clustering_minimum_core_cluster_size_at_formation:=3}"
echo "causal_clustering_minimum_core_cluster_size_at_runtime" "${causal_clustering_minimum_core_cluster_size_at_runtime:=3}"

echo "dbms_default_listen_address" "${dbms_default_listen_address:=0.0.0.0}"
echo "dbms_mode" "${dbms_mode:=SINGLE}"
echo "causal_clustering_discovery_listen_address" "${causal_clustering_discovery_listen_address:=0.0.0.0:5000}"

# Logging
echo "dbms_logs_http_enabled" "${dbms_logs_http_enabled:=true}"
echo "dbms_logs_gc_enabled" "${dbms_logs_gc_enabled:=true}"
echo "dbms_logs_debug_level" "${dbms_logs_debug_level:=INFO}"

# Misc
echo "dbms_security_allow_csv_import_from_file_urls" "${dbms_security_allow_csv_import_from_file_urls:=true}"

# Get a google metadata key, returning a default value
# if it is not defined
getMetadata() {
   # Metadata key: $1
   # Default value: $2
   # Return: modify $METADATA_REQUEST
   # echo "Looking for key $1 with default value $2"
   published=$(curl -s -S -f -H "Metadata-Flavor: Google" \
      "$INSTANCE_API/attributes/$1" 2>/dev/null)
   # echo "Actual value of $1 was '$published'"
   if [ -z "$published" ]; then
      METADATA_REQUEST=$2
   else
      METADATA_REQUEST=$published
   fi 
   # echo "Returning value $METADATA_REQUEST"
}

# For each config item, set an env var to the appropriate
# metadata value or default value.  This sets us up for envsubst
for setting in "${!NEO4J_SETTINGS[@]}" ; do
   # echo "SETTING " $setting " DEFAULT " ${NEO4J_SETTINGS[$setting]};
   getMetadata $setting "${NEO4J_SETTINGS[$setting]}"
   echo "Setting $setting to $METADATA_REQUEST"
   echo ""

   # Set the variable named setting to the result.
   # See: https://stackoverflow.com/questions/9714902/how-to-use-a-variables-value-as-another-variables-name-in-bash
   export $setting="$METADATA_REQUEST"
done

export EXTERNAL_IP_ADDR=$(curl -s -H "Metadata-Flavor: Google" \
   $INSTANCE_API/network-interfaces/0/access-configs/0/external-ip)

echo "pre-neo4j.sh: External IP $EXTERNAL_IP_ADDR"

export INTERNAL_HOSTNAME=$(curl -s -H "Metadata-Flavor: Google" \
   $INSTANCE_API/hostname)

echo "pre-neo4j.sh Internal hostname $INTERNAL_HOSTNAME"

# Google VMs don't have ifconfig.
# Output of ip addr looks like this:

# 2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1460 qdisc pfifo_fast state UP group default qlen 1000
#   link/ether 42:01:0a:8a:00:04 brd ff:ff:ff:ff:ff:ff
#   inet 10.138.0.4/32 brd 10.138.0.4 scope global eth0
#      valid_lft forever preferred_lft forever
#   inet6 fe80::4001:aff:fe8a:4/64 scope link
#      valid_lft forever preferred_lft forever
# So we're pulling just the 10.138.0.4 part.
export INTERNAL_IP_ADDR=$(curl -s -H "Metadata-Flavor: Google" $INSTANCE_API/network-interfaces/0/ip)

echo "pre-neo4j.sh internal IP $INTERNAL_IP_ADDR"

echo "pre-neo4j.sh environment for configuration setup"
env

# These substitutions guarantee that the declared google metadata
# impacts what the server sees on startup.
envsubst < /etc/neo4j/neo4j.template > /etc/neo4j/neo4j.conf

echo "pre-neo4j.sh: Starting neo4j console..."

# This is the same command sysctl's service would have executed.
exec /usr/share/neo4j/bin/neo4j console
