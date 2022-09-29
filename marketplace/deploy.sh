#!/bin/bash

STACK_NAME=$1

TEMPLATE_BODY="file://neo4j.template.yaml"
REGION=`aws configure get region`

Password="foo123"
CoreInstanceCount="3"
ReadReplicaCount="2"
SSHCIDR="0.0.0.0/0"
GraphDatabaseVersion=5.0.0
S3AccessKeyId=$2
S3SecretAccessKey=$3

aws cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name ${STACK_NAME} \
--template-body ${TEMPLATE_BODY} \
--region ${REGION} \
--disable-rollback \
--parameters \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=S3AccessKeyId,ParameterValue=${S3AccessKeyId} \
ParameterKey=S3SecretAccessKey,ParameterValue=${S3SecretAccessKey} \
ParameterKey=GraphDatabaseVersion,ParameterValue=${GraphDatabaseVersion} \
ParameterKey=CoreInstanceCount,ParameterValue=${CoreInstanceCount} \
ParameterKey=SSHCIDR,ParameterValue=${SSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=False \
ParameterKey=InstallBloom,ParameterValue=False \
ParameterKey=ReadReplicaCount,ParameterValue=${ReadReplicaCount}
