#!/bin/bash

export RUN_ID=$(head -c 1024 /dev/urandom | md5)
export PROJECT=neo4j-k8s-marketplace-public
export DEPLOY_ID=$(head -c 10 /dev/urandom | md5 | head -c 5)
export SOLUTION_VERSION=3.5
export IMAGE=gcr.io/neo4j-k8s-marketplace-public/causal-cluster:$SOLUTION_VERSION
export APP_INSTANCE_NAME=deploy-$DEPLOY_ID
export CLUSTER_PASSWORD=mySecretPassword
export CORES=3
export READ_REPLICAS=0
export CPU_REQUEST=200m
export MEMORY_REQUEST=1Gi
export CPU_LIMIT=2
export MEMORY_LIMIT=4Gi
export VOLUME_SIZE=4Gi
export STORAGE_CLASS_NAME=standard
export NAMESPACE=default

PATH_TO_CHART=chart/

helm template $PATH_TO_CHART --name $APP_INSTANCE_NAME \
   --set namespace=$NAMESPACE \
   --set image=$IMAGE \
   --set name=$APP_INSTANCE_NAME \
   --set neo4jPassword=$CLUSTER_PASSWORD \
   --set authEnabled=true \
   --set coreServers=$CORES \
   --set readReplicaServers=$READ_REPLICAS \
   --set cpuRequest=$CPU_REQUEST \
   --set memoryRequest=$MEMORY_REQUEST \
   --set cpuLimit=$CPU_LIMIT \
   --set memoryLimit=$MEMORY_LIMIT \
   --set volumeSize=$VOLUME_SIZE \
   --set volumeStorageClass=$STORAGE_CLASS_NAME \
   --set acceptLicenseAgreement=yes > $APP_INSTANCE_NAME.yaml

if [ $? -ne 0 ] ; then
    echo "Helm expansion failed"
    exit 1
fi

# Kick off the cluster.
kubectl apply -f $APP_INSTANCE_NAME.yaml

if [ $? -ne 0 ] ; then
  echo "Kubectl failed"
  exit 1
fi

echo BENCHMARK_SETTING_CHART=$APP_INSTANCE_NAME.yaml

sleep 10

CLUSTER_PASSWORD=$(kubectl get secrets $APP_INSTANCE_NAME-neo4j-secrets -o yaml | grep neo4j-password: | sed 's/.*neo4j-password: *//' | base64 --decode)

if [ $? -ne 0 ] ; then
   echo "Failed to retrieve cluster password"
   echo STACK_NAME=$APP_INSTANCE_NAME
   exit 1
fi

echo "Got cluster password"

tries=0
LEADER=unknown
while true ; do 
    SHELL_POD=cypher-shell-$DEPLOY_ID
    OUTPUT=$(kubectl run -it --rm $SHELL_POD \
        --image=gcr.io/cloud-marketplace/neo4j-public/causal-cluster-k8s:$SOLUTION_VERSION \
        --restart=Never \
        --namespace=$NAMESPACE \
        --command -- ./bin/cypher-shell -u neo4j \
        -p "$CLUSTER_PASSWORD" \
        --format plain \
        -a $APP_INSTANCE_NAME-neo4j.$NAMESPACE.svc.cluster.local \
        "call dbms.cluster.overview() yield addresses, role where role='LEADER' return addresses[0];" 2>&1)
    SHELL_EXIT=$?

    echo "Cypher shell reports:"
    echo "========== CYPHER SHELL ============="
    echo $OUTPUT
    echo "========== /CYPHER SHELL ============"

    if [ $SHELL_EXIT -eq 0 ] ; then
        echo "Pods are ready ($tries tries)"

        LEADER=$(echo $OUTPUT | grep $APP_INSTANCE_NAME)
        break
    fi

    if [ $tries -gt 40 ] ; then
        echo "Pods are not coming up....giving up"
        exit 1
    fi

    tries=$(($tries+1))
    echo "Pods not ready yet ($tries tries)"
    sleep 3
done

# LEADER contains the bolt address, like this:
# bolt://deploy-e9969-neo4j-core-2.deploy-e9969-neo4j.default.svc.cluster.local:7687
# Trim this down to just the pod name deploy-e9969-neo4j-core-2
echo "Leader address is $LEADER"
LEADER_POD=$(echo $LEADER | sed 's|^.*://||' | sed 's|\..*$||')
echo "Leader pod is $LEADER_POD"
exec nohup kubectl port-forward $LEADER_POD 7687:7687 7474:7474 >kubectl-$APP_INSTANCE_NAME.log 2>&1 &

# Provider settings
echo BENCHMARK_SETTING_LEADER_POD=$LEADER_POD
echo BENCHMARK_SETTING_PROJECT=$PROJECT
echo BENCHMARK_SETTING_DEPLOY_ID=$DEPLOY_ID
echo BENCHMARK_SETTING_SOLUTION_VERSION=$SOLUTION_VERSION
echo BENCHMARK_SETTING_IMAGE=$IMAGE
echo BENCHMARK_SETTING_APP_INSTANCE_NAME=$APP_INSTANCE_NAME
echo BENCHMARK_SETTING_CORES=$CORES
echo BENCHMARK_SETTING_READ_REPLICAS=$READ_REPLICAS
echo BENCHMARK_SETTING_CPU_REQUEST=$CPU_REQUEST
echo BENCHMARK_SETTING_CPU_LIMIT=$CPU_LIMIT
echo BENCHMARK_SETTING_MEMORY_REQUEST=$MEMORY_REQUEST
echo BENCHMARK_SETTING_MEMORY_LIMIT=$MEMORY_LIMIT
echo BENCHMARK_SETTING_VOLUME_SIZE=$VOLUME_SIZE
echo BENCHMARK_SETTING_STORAGE_CLASS_NAME=$STORAGE_CLASS_NAME
echo BENCHMARK_SETTING_NAMESPACE=$NAMESPACE

# API requirements.
echo RUN_ID=$RUN_ID
echo NEO4J_URI=bolt://localhost:7687
echo NEO4J_PASSWORD=$CLUSTER_PASSWORD
echo STACK_NAME=$APP_INSTANCE_NAME

exit 0