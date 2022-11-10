#!/bin/bash

STACK_NAME=$1
TEMPLATE_BODY="file://alb_with_ssl.yaml"
REGION=$(aws configure get region)

Password="testpass123"
NumberOfServers="3"
SSHCIDR="0.0.0.0/0"
GraphDatabaseVersion=5.1.0
KeyName="edr-us-east-1"

#Update with your SSLDomain
SSLDomain="neo4j.edrandall.uk"

#Update with the ARN of the Certificate from AWS Certificate Manager
CertificateARN="arn:aws:acm:us-east-1:540622579701:certificate/f544dc8f-887d-4b4a-929a-549234e178e7"

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
ParameterKey=SSHCIDR,ParameterValue=${SSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=False \
ParameterKey=InstallBloom,ParameterValue=False \
ParameterKey=SSLDomain,ParameterValue=${SSLDomain} \
ParameterKey=CertificateARN,ParameterValue=${CertificateARN} \
ParameterKey=KeyName,ParameterValue=${KeyName}

