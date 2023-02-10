#!/bin/bash

#
# Script:  deploy.sh
# Purpose: This script can be used to deploy the Neo4j CloudFormation template if the aws cli
#          is correctly installed and configured
#

###################################################################################

# User configurable variables
CoreInstanceCount=3
SSHCIDR="0.0.0.0/0"
InstallGraphDataScience="No"
InstallBloom="No"
REGION="us-east-1"
Password="foobar123%"
graphDataScienceLicenseKey="None"
bloomLicenseKey="None"
ReadReplicaCount=2

###################################################################################

# Other Variables (changes not normally required)
AWS=$(basename "$(which aws)") ||  { echo "Please ensure that the AWS cli client is installed." && exit 1; };
STACK_NAME=$1
TEMPLATE_BODY="file://neo4j.template.yaml"

###################################################################################

if [ $CoreInstanceCount == 2 ] || [ $CoreInstanceCount -gt 10 ] || [ $CoreInstanceCount -lt 1 ]; then
  echo "A single instance, or between 3 and 10 instances can be installed."
  exit 1
fi

if [ $InstallGraphDataScience == "Yes" ] && [ $CoreInstanceCount != 1 ] ; then
  echo "GDS cannot be installed on a cluster. CoreInstanceCount must be set to \"1\" if InstallGraphDataScience is set to \"No\"."
  exit 1
fi

if [ "$#" != 1 ] ; then
  echo "This script takes a single argument, the desired name of the target cloudformation stack."
  echo "Usage: { $0 [stack-name] }"
  exit 1
fi

###################################################################################

$AWS cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name $STACK_NAME \
--template-body $TEMPLATE_BODY \
--region $REGION \
--disable-rollback \
--parameters \
--profile product-na \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=CoreInstanceCount,ParameterValue=${CoreInstanceCount} \
ParameterKey=SSHCIDR,ParameterValue=${SSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=${InstallGraphDataScience} \
ParameterKey=GraphDataScienceLicenseKey,ParameterValue=${graphDataScienceLicenseKey} \
ParameterKey=InstallBloom,ParameterValue=${InstallBloom} \
ParameterKey=BloomLicenseKey,ParameterValue=${bloomLicenseKey} \
ParameterKey=ReadReplicaCount,ParameterValue=${ReadReplicaCount}
