#!/bin/bash

#
# Script:      deploy.sh
# Purpose:     This script can be used to deploy the Neo4j Enterprise CloudFormation template.
# Prequisites: The aws cli must be correctly installed and configured.
#

###################################################################################

STACK_NAME=$1
TEMPLATE_BODY="file://neo4j-nlb-priv-ssl.template.yaml"

# User configurable variables
NumberOfServers=3
BastionSSHCIDR="0.0.0.0/0"
InstallGraphDataScience="No"
InstallBloom="No"
REGION="us-east-2"
Password="foobar123%"
graphDataScienceLicenseKey="None"
bloomLicenseKey="None"
SSHKeyName="jhair-neo4j-us-east-2"

# Update with your Route 53 Hosted Zone Id
R53HostedZoneId="XXXXXXXXXXXXXXXXXXXX"
# Update with your SSL Name to create the SSL certificates and DNS entry within Route 53
SSLDomain="jshair.neo4j-field.com"

# Other Variables (changes not normally required)
AWS=$(basename "$(which aws)") ||  { echo "Please ensure that the AWS cli client is installed." && exit 1; };

###################################################################################
if [ $NumberOfServers == 2 ] || [ $NumberOfServers -gt 10 ] || [ $NumberOfServers -lt 1 ]; then
  echo "A single instance, or between 3 and 10 instances can be installed."
  exit 1
fi

if [ $InstallGraphDataScience == "Yes" ] && [ $NumberOfServers != 1 ] ; then
  echo "GDS cannot be installed on a cluster. NumberOfServers must be set to \"1\" if InstallGraphDataScience is set to \"True\"."
  exit 1
fi

if [ "$#" != 1 ] ; then
  echo "This script takes a single argument, the desired name of the target cloudformation stack."
  echo "Usage: { $0 [stack-name] }"
  exit 1
fi

###################################################################################

$AWS cloudformation create-stack \
--capabilities CAPABILITY_IAM \
--stack-name $STACK_NAME \
--template-body $TEMPLATE_BODY \
--region $REGION \
--disable-rollback \
--parameters \
ParameterKey=Password,ParameterValue=${Password} \
ParameterKey=NumberOfServers,ParameterValue=${NumberOfServers} \
ParameterKey=BastionSSHCIDR,ParameterValue=${BastionSSHCIDR} \
ParameterKey=InstallGraphDataScience,ParameterValue=${InstallGraphDataScience} \
ParameterKey=GraphDataScienceLicenseKey,ParameterValue=${graphDataScienceLicenseKey} \
ParameterKey=InstallBloom,ParameterValue=${InstallBloom} \
ParameterKey=BloomLicenseKey,ParameterValue=${bloomLicenseKey} \
ParameterKey=R53HostedZoneId,ParameterValue=${R53HostedZoneId} \
ParameterKey=SSHKeyName,ParameterValue=${SSHKeyName} \
ParameterKey=SSLDomain,ParameterValue=${SSLDomain}