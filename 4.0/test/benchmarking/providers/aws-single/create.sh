#!/bin/bash
#
# This is mostly similar to the way we create a stack for an AWS cluster.
# The main differences are the template URL used, and the parameters you pass
# to the cluster, and the way we get the final IP
########################################################################

# Pull in variables we'll need.
. settings.sh

# Returns a StackID that can be used to delete.
echo "Creating stack..."
STACK_ID=$(aws cloudformation create-stack \
   --stack-name $STACKNAME \
   --region $REGION \
   --template-url $STANDALONE_TEMPLATE \
   --parameters ParameterKey=InstanceType,ParameterValue=$INSTANCE \
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
echo BENCHMARK_SETTING_TEMPLATE=$STANDALONE_TEMPLATE

echo $STACK_ID 

echo "Waiting for create to complete...."
aws cloudformation wait stack-create-complete --region us-east-1 --stack-name "$STACK_ID"

echo "Getting outputs"
JSON=$(aws cloudformation describe-stacks --region us-east-1 --stack-name "$STACK_ID")

echo $JSON

echo "Assembling results"
STACK_NAME=$(echo $JSON | jq -r .Stacks[0].StackName)
WEBADMIN=$(echo $JSON | jq -cr '.Stacks[0].Outputs[] | select(.OutputKey | contains("Neo4jWebadmin")) | .OutputValue')

echo BENCHMARK_SETTING_STACK_NAME=$STACK_NAME
echo BENCHMARK_SETTING_WEBADMIN=$WEBADMIN

# WEBADMIN ends up being https://1.2.3.4:7473/, trim to IP address
NEO4J_IP=$(echo $WEBADMIN | sed 's|https://||' | sed 's|:.*$||')
NEO4J_PASSWORD=$(echo $JSON | jq -cr '.Stacks[0].Outputs[] | select(.OutputKey | contains("Password")) | .OutputValue')

echo RUN_ID=$RUN_ID
echo STACK_NAME=$STACK_NAME
echo STACK_ID=$STACK_ID
echo NEO4J_URI=bolt://$NEO4J_IP
echo NEO4J_PASSWORD=$NEO4J_PASSWORD