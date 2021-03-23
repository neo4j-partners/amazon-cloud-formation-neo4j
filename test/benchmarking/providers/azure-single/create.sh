#!/bin/bash
export RUN_ID=$(head -c 1024 /dev/urandom | md5)
export LOCATION=eastus
export SUBSCRIPTION=Private-PAYG
export RG=neo4j-standalone-RG-$(head -c 3 /dev/urandom | base64 | sed 's|[^A-Za-z0-9]|x|g')
export NAME=neo4j-standalone
export ADMIN_USERNAME=graph-hacker
export ADMIN_PASSWORD=ch00se:A@PASSw0rd
export NEO4J_PASSWORD=ch00se:A@PASSw0rd
export NETWORK_SECURITY_GROUP=neo4j-nsg

# Options: https://azure.microsoft.com/en-us/pricing/details/virtual-machines/
export VM_SIZE=Standard_D2_v3

# Can change this to static if desired
export ADDRESS_ALLOCATION=dynamic

# Configuration bits of what you're launching
# Publisher:Offer:Sku:Version
export PUBLISHER=neo4j
export OFFER=neo4j-enterprise-4_1
export SKU=neo4j_4_1_1_apoc
export VERSION=latest
export IMAGE=$PUBLISHER:$OFFER:$SKU:$VERSION

echo "Creating resource group named $RG"
az group create --location $LOCATION \
    --name $RG \
    --subscription $SUBSCRIPTION

echo "Creating Network Security Group named $NETWORK_SECURITY_GROUP"
az network nsg create \
    --resource-group $RG \
    --location $LOCATION \
    --name $NETWORK_SECURITY_GROUP

echo "Assigning NSG rules to allow inbound traffic on Neo4j ports..."
prio=1000
for port in 7473 7474 7687; do
    az network nsg rule create \
        --resource-group $RG \
        --nsg-name "$NETWORK_SECURITY_GROUP" \
        --name neo4j-allow-$port \
        --protocol tcp \
        --priority $prio \
        --destination-port-range $port
    prio=$(($prio+1))
done

echo "Creating Neo4j VM named $NAME"
az vm create --name $NAME \
    --resource-group $RG \
    --image $IMAGE \
    --vnet-name $NAME-vnet \
    --subnet $NAME-subnet \
    --admin-username "$ADMIN_USERNAME" \
    --admin-password "$ADMIN_PASSWORD" \
    --public-ip-address-allocation $ADDRESS_ALLOCATION \
    --size $VM_SIZE

if [ $? -ne 0 ] ; then
    echo "VM creation failed"
    exit 1
fi 

echo "Updating NIC to have our NSG"
# Uses default assigned NIC name
az network nic update \
    --resource-group "$RG" \
    --name "${NAME}VMNic" \
    --network-security-group "$NETWORK_SECURITY_GROUP"

# Get the IP address of our instance
IP_ADDRESS=$(az vm list-ip-addresses -g "$RG" -n "$NAME" | jq -r '.[0].virtualMachine.network.publicIpAddresses[0].ipAddress')

echo NEO4J_URI=bolt://$IP_ADDRESS

# Change password
echo "Checking if Neo4j is up and changing password...."
while true; do
    if curl -s -I http://$IP_ADDRESS:7474 | grep "200 OK"; then
        echo "Neo4j is up; changing default password" 2>&1

        curl -v -H "Content-Type: application/json" \
                -XPOST -d '{"password":"'$NEO4J_PASSWORD'"}' \
                -u neo4j:neo4j \
                http://$IP_ADDRESS:7474/user/neo4j/password \
                2>&1
        echo "Password reset, signaling success" 2>&1
        break
    fi

    echo "Waiting for neo4j to come up" 2>&1
    sleep 1
done

echo BENCHMARK_SETTING_LOCATION=$LOCATION
echo BENCHMARK_SETTING_SUBSCRIPTION=$SUBSCRIPTION
echo BENCHMARK_SETTING_IMAGE=$IMAGE
echo BENCHMARK_SETTING_VM_SIZE=$VM_SIZE

echo STACK_NAME=$RG
echo NEO4J_URI=$NEO4J_URI
echo NEO4J_PASSWORD=$NEO4J_PASSWORD
echo RUN_ID=$RUN_ID
exit 0
