#!/bin/bash
#
# Simple utility for checking various things across cluster members.
# Run this, pipe it to output somewhere, and inspect to quickly check
# key setup aspects of all VMs in a cluster.
#
# Adjust STACK_NAME and KEY_LOCATION for whatever you deployed and run.
export STACK_NAME=neo4j-cloudlauncher-testdeploy-4-2-0
export KEY_LOCATION=~/.aws/bfeshti.pem

CLUSTER_PUBLIC_IPS=$(aws ec2 describe-instances --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME" --query 'Reservations[*].Instances[*].NetworkInterfaces[*].Association.PublicIp' --output text)

for ip in $CLUSTER_PUBLIC_IPS ; do
   echo ""
   echo "================================"
   echo "CLUSTER MEMBER " $ip
   echo "================================"
   echo "Filesystem mounts:"
   ssh -o "StrictHostKeyChecking no" -i "$KEY_LOCATION" ubuntu@$ip "df -h"
   echo ""
   echo "Neo4j REST API accessible?"
   ssh -o "StrictHostKeyChecking no" -i "$KEY_LOCATION" ubuntu@$ip "curl -s http://localhost:7474/"
   echo ""
   echo "Startup log dump"
   ssh -o "StrictHostKeyChecking no" -i "$KEY_LOCATION" ubuntu@$ip "cat /home/ubuntu/setup.log"
done
