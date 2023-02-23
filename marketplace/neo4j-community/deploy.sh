#!/bin/bash

#
# Script:  deploy-neo4j-community.sh
# Purpose: This script can be used to deploy the Neo4j CloudFormation template if the aws cli
#          is correctly installed and configured
#

###################################################################################

# User configurable variables
SSHCIDR="0.0.0.0/0"
REGION="us-east-1"
Password="foobar123"

###################################################################################

# Other Variables (changes not normally required)
AWS=$(basename "$(which aws)") ||  { echo "Please ensure that the AWS cli client is installed." && exit 1; };
STACK_NAME=$1
TEMPLATE_BODY="file://neo4j.template.yaml"

###################################################################################

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
ParameterKey=SSHCIDR,ParameterValue=${SSHCIDR} 