#!/bin/bash

echo "Deleting stack $1"
aws cloudformation delete-stack --stack-name "$1" --region us-east-1

exit $?