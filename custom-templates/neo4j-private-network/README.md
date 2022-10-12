# Neo4j Private Network 

## Deploying a 3-node Neo4j cluster using AWS CloudFormation in Private [Non-Internet Routable] Subnets

The "neo4j-private-network" Cloud Formation template delivers an AWS environment running neo4j, with database instances which are *not* (inbound) internet routable.

To deploy this cloudformation stack, the following steps must be undertaken:

1) Ensure that the AWS CLI properly installed and configured for the target AWS account.  Details on how to do this can be found in the [AWS CLI Documentation](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html)

2) Clone the [Neo4j AWS CloudFormation repository](
https://github.com/neo4j-partners/amazon-cloud-formation-neo4j) to a local workstation.  


3) Change to the directory ```custom-templates/neo4j-private-netowork``` and edit the file ```deploy.sh``` and update the variables containted within it:

```
Password="set-neo4j-password-here"
CoreInstanceCount="3"
ReadReplicaCount="0"
SSHCIDR="0.0.0.0/0"
GraphDatabaseVersion=4.4.12
KeyName="name-of-ssh-key"
```

4) Run the deploy.sh script.  It takes a single argument which is the desired CloudFormation Stack name:
./deploy.sh my-test-stack

5) Log into the AWS console to check the build status of the CloudFormation Template.  The template provides a single output, the command needed to create an SSH tunnel to test the Neo4j cluster via the bastion instance.

![](neo4j-aws-3-node-private.png?raw=true)
