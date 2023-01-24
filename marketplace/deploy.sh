#!/bin/bash

#
# Script:  deploy.sh
# Purpose: This script can be used to deploy the Neo4j CloudFormation template if the aws cli
#          is correctly installed and configured
#

###################################################################################

# User configurable variables
Password="foobar123"
NumberOfServers=1
SSHCIDR="0.0.0.0/0"
InstallGraphDataScience="True"
InstallBloom="False"
REGION="eu-central-1"
Password="foobar123"
graphDataScienceLicenseKey="None"

###################################################################################

# Other Variables (changes not normally required)
AWS=$(basename "$(which aws)") ||  { echo "Please ensure that the AWS cli client is installed." && exit 1; };
STACK_NAME=$1
TEMPLATE_BODY="file://neo4j.template.yaml"

###################################################################################

if [ $NumberOfServers == 2 ] || [ $NumberOfServers -gt 10 ] || [ $NumberOfServers -lt 1 ]; then
  echo "A single instance, or between 3 and 10 instances can be installed."
  exit 1
fi

if [ $InstallGraphDataScience == "True" ] && [ $NumberOfServers != 1 ] ; then
  echo "GDS cannot be installed on a cluster. NumberOfServers must be set to \"1\" if InstallGraphDataScience is set to \"True\"."
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
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=NumberOfServers,ParameterValue=${NumberOfServers} \
ParameterKey=SSHCIDR,ParameterValue=${SSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=${InstallGraphDataScience} \
ParameterKey=GraphDataScienceLicenseKey,ParameterValue=${graphDataScienceLicenseKey} \
ParameterKey=InstallBloom,ParameterValue=${InstallBloom}
