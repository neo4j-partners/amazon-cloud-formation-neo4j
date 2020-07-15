#!/bin/bash

if [ -z $1 ] ; then
   echo "Missing argument"
   exit 1
fi

echo "Deleting stack $1"

echo "Killing port forwarding"
kill -9 $(ps -A | grep -m1 "kubectl port-forward" | awk '{print $1}')

# Delete the stack by tearing down all of the resources in the YAML we created
# as part of the create step.
kubectl delete -f "$1.yaml"

# Delete PVCs
kubectl delete pvc -l release=$1 

KUBECTL_EXIT=$?
rm -f "$1.yaml"

echo "Dumping kubectl forward logs for posterity..."
echo "========================"
cat kubectl-$1.log
echo "========================"

rm -f "kubectl-$1.log" nohup.out

exit $KUBECTL_EXIT