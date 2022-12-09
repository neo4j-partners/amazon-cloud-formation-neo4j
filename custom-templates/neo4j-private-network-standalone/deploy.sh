#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://neo4j.template.yaml"
#REGION=`aws configure get region`

REGION=us-west-1
Password="foo123"
CoreInstanceCount="1"
ReadReplicaCount="0"
SSHCIDR="0.0.0.0/0"
KeyName="harshit-uswest1"

aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name ${STACK_NAME} \
--template-body ${TEMPLATE_BODY} \
--region ${REGION} \
--disable-rollback \
--parameters \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=CoreInstanceCount,ParameterValue=${CoreInstanceCount} \
ParameterKey=SSHCIDR,ParameterValue=${SSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=False \
ParameterKey=InstallBloom,ParameterValue=False \
ParameterKey=ReadReplicaCount,ParameterValue=${ReadReplicaCount} \
ParameterKey=KeyName,ParameterValue=${KeyName}
