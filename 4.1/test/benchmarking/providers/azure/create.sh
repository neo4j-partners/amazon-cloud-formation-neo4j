#!/bin/bash
export RUN_ID=$(head -c 1024 /dev/urandom | md5)
export CORE_NODES=3
export READ_REPLICAS=0
export NEO4J_PASSWORD=s00pers3cR3T:
export ADMIN_AUTH_TYPE=password
export USERNAME=graph-hacker
export ADMIN_PASSWORD=s00pers3cR3T:
export VM_SIZE=Standard_B2ms
export DISK_TYPE=StandardSSD_LRS
export DISK_SIZE=256
export IP_ALLOCATION=Dynamic
export SEED=$(head -c 3 /dev/urandom | base64 | sed 's/[^a-zA-Z0-9]/X/g')
export RESOURCE_GROUP="bm-${SEED}"
export CLUSTERNAME="neo4j-${SEED}"
export DEPLOYMENT=neo4j-bmdeploy
export LOCATION="East US"

# The ARM template to deploy
export TEMPLATE_BASE=http://neo4j-arm.s3.amazonaws.com/4.1.3/causal-cluster/
export TEMPLATE_URL=${TEMPLATE_BASE}mainTemplate.json

echo $(cat <<JSON
{
    "ClusterName": { "value": "${CLUSTERNAME}" },
    "CoreNodes": { "value": ${CORE_NODES} },
    "ReadReplicas": { "value": ${READ_REPLICAS} },
    "VmSize": { "value": "${VM_SIZE}" },
    "DataDiskType": { "value": "${DISK_TYPE}" },
    "DataDiskSizeGB": { "value": ${DISK_SIZE} },
    "AdminUserName": { "value": "${USERNAME}" },
    "AdminAuthType": { "value": "${ADMIN_AUTH_TYPE}" },
    "AdminCredential": { "value": "${ADMIN_PASSWORD}" },
    "PublicIPAllocationMethod": { "value": "${IP_ALLOCATION}" },
    "Neo4jPassword": { "value": "${NEO4J_PASSWORD}" },
    "_artifactsLocation": { "value": "${TEMPLATE_BASE}" }
}
JSON
) > "${RESOURCE_GROUP}.json"

echo BENCHMARK_SETTING_CORE_NODES=$CORE_NODES
echo BENCHMARK_SETTING_READ_REPLICAS=$READ_REPLICAS
echo BENCHMARK_SETTING_VM_SIZE=$VM_SIZE
echo BENCHMARK_SETTING_DISK_TYPE=$DISK_TYPE
echo BENCHMARK_SETTING_DISK_SIZE=$DISK_SIZE
echo BENCHMARK_SETTING_IP_ALLOCATION=$IP_ALLOCATION
echo BENCHMARK_SETTING_CLUSTERNAME=$CLUSTERNAME
echo BENCHMARK_SETTING_LOCATION=$LOCATION

echo "Creating resource group named ${RESOURCE_GROUP}"
if ! az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"; then
    echo STACK_NAME=$RESOURCE_GROUP
    echo "Failed to create necessary resource group ${RESOURCE_GROUP}"
    exit 1
fi

echo "Creating deployment"
az group deployment create \
    --template-uri "$TEMPLATE_URL" \
    --parameters @./${RESOURCE_GROUP}.json \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${DEPLOYMENT}"

if [ $? -ne 0 ] ; then
    echo STACK_NAME=$RESOURCE_GROUP
    echo "Stack deploy failed"
    exit 1
fi

# JSON Path to server response where IP address is.
ADDR_FIELD=".[].virtualMachine.network.publicIpAddresses[0].ipAddress"

IP_ADDRESS=$(az vm list-ip-addresses --resource-group "${RESOURCE_GROUP}" | jq -r "$ADDR_FIELD" | head -n 1)

echo STACK_NAME=$RESOURCE_GROUP
echo NEO4J_URI=bolt+routing://$IP_ADDRESS:7687
echo NEO4J_PASSWORD=$NEO4J_PASSWORD
