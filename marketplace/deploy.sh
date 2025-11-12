#!/bin/bash

STACK_NAME=$1
TEMPLATE_BODY="file://neo4j.template.yaml"
REGION="us-east-1"
NumberOfServers=3

aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name $STACK_NAME \
--template-body $TEMPLATE_BODY \
--region $REGION \
--parameters \
ParameterKey=NumberOfServers,ParameterValue=${NumberOfServers}
