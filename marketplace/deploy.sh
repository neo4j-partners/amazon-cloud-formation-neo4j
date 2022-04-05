#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://neo4j.template.yaml"
REGION=`aws configure get region`

Password="foo123"
KeyName="neo4j-${REGION}"
NodeCount="3"
SSHCIDR="0.0.0.0/0"

aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name ${STACK_NAME} \
--template-body ${TEMPLATE_BODY} \
--region ${REGION} \
--parameters \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=KeyName,ParameterValue=${KeyName} \
ParameterKey=NodeCount,ParameterValue=${NodeCount} \
ParameterKey=SSHCIDR,ParameterValue=${SSHCIDR}
