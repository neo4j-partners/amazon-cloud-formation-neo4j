export VERSION=3.5.16
export STANDALONE_TEMPLATE=http://neo4j-cloudformation.s3.amazonaws.com/neo4j-enterprise-standalone-stack-$VERSION.json
export TEMPLATE=http://neo4j-cloudformation.s3.amazonaws.com/neo4j-enterprise-stack-$VERSION.json
export STACKNAME=neo4j-testdeploy-$(echo $VERSION | sed s/[^A-Za-z0-9]/-/g)-$(head -c 3 /dev/urandom | md5 | head -c 5)
# General purpose, 2 cpu, 8gb RAM
export INSTANCE=m5.large
export REGION=us-east-1
export SSHKEY=bfeshti
export DISK_GB=64
# General purpose disk
export DISK_TYPE=gp2
# Throughput optimized HDD
# export DISK_TYPE=st1

export RUN_ID=$(head -c 1024 /dev/urandom | md5)

