#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://neo4j.template.yaml"
REGION=`aws configure get region`

Password="foo123"
KeyName="neo4j-${REGION}"
NodeCount="3"
GraphDataScienceVersion="None"

aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name ${STACK_NAME} \
--template-body ${TEMPLATE_BODY} \
--region ${REGION} \
--parameters \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=KeyName,ParameterValue=${KeyName} \
ParameterKey=NodeCount,ParameterValue=${NodeCount} \
ParameterKey=GraphDataScienceVersion,ParameterValue=${GraphDataScienceVersion} \
ParameterKey=LicenseKey,ParameterValue="None"

#ParameterKey=LicenseKey,ParameterValue=$( cat neo4j.license )
