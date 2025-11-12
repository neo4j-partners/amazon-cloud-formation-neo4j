#!/bin/bash

STACK_NAME=$1
TEMPLATE_BODY="file://neo4j.template.yaml"
REGION="us-east-1"
Password="foobar123"

aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name $STACK_NAME \
--template-body $TEMPLATE_BODY \
--region $REGION \
--parameters \
ParameterKey=Password,ParameterValue=${Password}
