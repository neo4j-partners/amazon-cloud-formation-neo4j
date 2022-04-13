#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://neo4j.template.yaml"
REGION=`aws configure get region`

AdminPassword="foo123"
KeyName="neo4j-${REGION}"
NodeCount="1"

aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name ${STACK_NAME} \
--template-body ${TEMPLATE_BODY} \
--region ${REGION} \
--parameters \
ParameterKey=AdminPassword,ParameterValue=${AdminPassword} \
ParameterKey=KeyName,ParameterValue=${KeyName} \
ParameterKey=NodeCount,ParameterValue=${NodeCount} \
ParameterKey=InstallGraphDataScience,ParameterValue="true" \
ParameterKey=InstallBloom,ParameterValue="true" \
ParameterKey=GraphDatabaseVersion,ParameterValue="4.4.5" \
ParameterKey=GraphDataScienceLicenseKey,ParameterValue="None" \
ParameterKey=BloomLicenseKey,ParameterValue="None" \
ParameterKey=GraphDataScienceVersion,ParameterValue="None" \
ParameterKey=BloomVersion,ParameterValue="None" \
ParameterKey=ApocVersion,ParameterValue="None"