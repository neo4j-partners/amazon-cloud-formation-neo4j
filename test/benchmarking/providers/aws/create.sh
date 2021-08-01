#!/bin/bash

<<<<<<< HEAD:test/benchmarking/providers/aws/create.sh
export VERSION=4.3.0
=======
export VERSION=4.3.2
>>>>>>> neo4j-v4.3.0:4.1/test/benchmarking/providers/aws/create.sh
export STANDALONE_TEMPLATE=http://neo4j-cloudformation.s3.amazonaws.com/neo4j-enterprise-standalone-stack-$VERSION.json
export TEMPLATE=http://neo4j-cloudformation.s3.amazonaws.com/neo4j-enterprise-stack-$VERSION.json
export STACKNAME=neo4j-testdeploy-$(echo $VERSION | sed s/[^A-Za-z0-9]/-/g)-$(head -c 3 /dev/urandom | md5 | head -c 5)
# General purpose, 2 cpu, 8gb RAM
export INSTANCE=m5.large
export REGION=us-east-1
export SSHKEY=david.allen.local
export DISK_GB=64
# General purpose disk
export DISK_TYPE=gp2
# Throughput optimized HDD
# export DISK_TYPE=st1

export RUN_ID=$(head -c 1024 /dev/urandom | md5)

# Returns a StackID that can be used to delete.
echo "Creating stack..."
STACK_ID=$(aws cloudformation create-stack \
   --stack-name $STACKNAME \
   --region $REGION \
   --template-url $TEMPLATE \
   --parameters ParameterKey=ClusterNodes,ParameterValue=3 \
                ParameterKey=InstanceType,ParameterValue=$INSTANCE \
                ParameterKey=NetworkWhitelist,ParameterValue=0.0.0.0/0 \
                ParameterKey=Password,ParameterValue=s00pers3cret \
                ParameterKey=SSHKeyName,ParameterValue=$SSHKEY \
                ParameterKey=VolumeSizeGB,ParameterValue=$DISK_GB \
                ParameterKey=VolumeType,ParameterValue=$DISK_TYPE \
  --capabilities CAPABILITY_NAMED_IAM | jq -r '.StackId')

# Stack settings
echo BENCHMARK_SETTING_CORE_NODES=3
echo BENCHMARK_SETTING_READ_REPLICAS=0
echo BENCHMARK_SETTING_MACHINE_TYPE=$INSTANCE
echo BENCHMARK_SETTING_REGION=$REGION
echo BENCHMARK_SETTING_NEO4J=$VERSION
echo BENCHMARK_SETTING_DISK_GB=$DISK_GB
echo BENCHMARK_SETTING_DISK_TYPE=$DISK_TYPE
echo BENCHMARK_SETTING_TEMPLATE=$TEMPLATE

echo $STACK_ID 

echo "Waiting for create to complete...."
aws cloudformation wait stack-create-complete --region us-east-1 --stack-name "$STACK_ID"

echo "Getting outputs"
JSON=$(aws cloudformation describe-stacks --region us-east-1 --stack-name "$STACK_ID")

echo $JSON

echo "Assembling results"
STACK_NAME=$(echo $JSON | jq -r .Stacks[0].StackName)
NEO4J_IP=$(echo $JSON | jq -cr '.Stacks[0].Outputs[] | select(.OutputKey | contains("Node1Ip")) | .OutputValue')
NEO4J_PASSWORD=$(echo $JSON | jq -cr '.Stacks[0].Outputs[] | select(.OutputKey | contains("Password")) | .OutputValue')

echo RUN_ID=$RUN_ID
echo STACK_NAME=$STACK_NAME
echo STACK_ID=$STACK_ID
echo NEO4J_URI=bolt+routing://$NEO4J_IP
echo NEO4J_PASSWORD=$NEO4J_PASSWORD