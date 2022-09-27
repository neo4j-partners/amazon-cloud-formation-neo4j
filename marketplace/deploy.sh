#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://neo4j.template.yaml"
REGION=`aws configure get region`

Password="foo123"
NodeCount="3"
SSHCIDR="0.0.0.0/0"
GraphDatabaseVersion=5.0.0
S3AccessKeyId=$1
S3SecretAccessKey=$2

aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name ${STACK_NAME} \
--template-body ${TEMPLATE_BODY} \
--region ${REGION} \
--parameters \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=S3AccessKeyId,ParameterValue=${S3AccessKeyId} \
ParameterKey=S3SecretAccessKey,ParameterValue=${S3SecretAccessKey} \
ParameterKey=GraphDatabaseVersion,ParameterValue=${GraphDatabaseVersion} \
ParameterKey=NodeCount,ParameterValue=${NodeCount} \
ParameterKey=SSHCIDR,ParameterValue=${SSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=False \
ParameterKey=InstallBloom,ParameterValue=False
