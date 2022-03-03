#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://existingvpc-neo4j.template.yaml"
REGION=`aws configure get region`

Password="foo123"
KeyName="neo4j-${REGION}"
VpcId="vpc-01ff3556321f6b0a2"
Subnets="\"subnet-0cda035ed69066e45,subnet-0e85ba4ebcebf4e03,subnet-09c4152602b3ff873\""

aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name ${STACK_NAME} \
--template-body ${TEMPLATE_BODY} \
--region ${REGION} \
--parameters \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=KeyName,ParameterValue=${KeyName} \
ParameterKey=VpcId,ParameterValue=${VpcId} \
ParameterKey=Subnets,ParameterValue=${Subnets}
