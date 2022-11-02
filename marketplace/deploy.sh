#!/bin/bash

#
# Script:  deploy.sh
# Purpose: This script can be used to deploy the Neo4j CloudFormation template if the aws cli
#          is correctly installed and configured
#

# User configurable variables
Password="foo123"
NodeCount="3"
SSHCIDR="0.0.0.0/0"

# Other Variables (changes not normally required)
AWS=$(which aws) ||  { echo "Please ensure that the AWS cli client is installed." && exit 1; };
STACK_NAME=$1
TEMPLATE_BODY="file://neo4j.template.yaml"
REGION=$(aws configure get region)

function usage {
  echo "This script takes a single argument, the desired name of the target cloudformation stack."
  echo "Usage: { $0 [stack-name] }"
  exit 1
}

[ "$1" != 1 ] && usage 

$AWS cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name ${STACK_NAME} \
--template-body ${TEMPLATE_BODY} \
--region ${REGION} \
--parameters \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=NodeCount,ParameterValue=${NodeCount} \
ParameterKey=SSHCIDR,ParameterValue=${SSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=False \
ParameterKey=InstallBloom,ParameterValue=False