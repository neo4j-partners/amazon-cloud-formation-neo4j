#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://neo4j-new.template.yaml"
#REGION=`aws configure get region`
REGION=us-east-1

Password="foo123"
NumberOfServers="3"
BastionSSHCIDR="0.0.0.0/0"
GraphDatabaseVersion=5.1.0
SSHKeyName="EdTest-us-east-1"


aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name ${STACK_NAME} \
--template-body ${TEMPLATE_BODY} \
--region ${REGION} \
--disable-rollback \
--parameters \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=GraphDatabaseVersion,ParameterValue=${GraphDatabaseVersion} \
ParameterKey=NumberOfServers,ParameterValue=${NumberOfServers} \
ParameterKey=BastionSSHCIDR,ParameterValue=${BastionSSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=False \
ParameterKey=InstallBloom,ParameterValue=False \
ParameterKey=SSHKeyName,ParameterValue=${SSHKeyName}
