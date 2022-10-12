# Neo4j Private Network CloudFormation Template


## Deploying a 3-node Neo4j cluster using AWS CloudFormation in Private [Non-Internet Routable] Subnets

*This "neo4j-private-network" Cloud Formation template delivers an AWS environment running neo4j, with database instances and a network load balancer which are not (inbound) internet routable:*

 - 3 node cluster
 - Neo4j v4.4.12
 
 
## Deployment Steps

To deploy this CloudFormation stack, the following steps must be undertaken:

1) Ensure that the AWS CLI properly installed and configured for the target AWS account.  Details on how to do this can be found in the [AWS CLI Documentation](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html)

2) Clone the [Neo4j AWS CloudFormation repository](
https://github.com/neo4j-partners/amazon-cloud-formation-neo4j) to a local workstation.  

3) Change to the directory ```amazon-cloud-formation-neo4j/custom-templates/neo4j-private-network``` and edit the file ```deploy.sh``` and update the variables containted therein:

```
Password="set-neo4j-password-here"
CoreInstanceCount="3"
ReadReplicaCount="0"
SSHCIDR="0.0.0.0/0"
GraphDatabaseVersion=4.4.12
KeyName="name-of-ssh-key"
```
Important Notes:
 - The ```CoreInstanceCount``` variable must retain the value of 3.  This template has not been tested with a single instance.
 - The KeyName variable must match the name of the keypair which is stored in AWS.  Therefore it must refer to a key name and and not a file name.
 
4) Ensure that the ```deploy.sh``` script is executable and run it.  (It takes a single argument which is the desired CloudFormation Stack name):
```
chmod 755 ./deploy.sh
./deploy.sh test-cloudformation-stack-name
```

5) Log into the AWS console to check the build status of the CloudFormation Template.  The template provides a single output, the command needed to create an SSH tunnel to test the Neo4j cluster via the bastion instance.

## Testing (with an SSH Tunnel)
Neither the Network Load Balancer, nor the databases instances are internet routable.  Therefore, the easiest way to test that the neo4j cluster is operational is to create an SSH tunnel to forward the database ports (7474 & 7686) from the database instances back to localhost.

The CloudFormation template provides an output showing the command needed to establish the tunnel.  In order for this work, it is recommended that ssh-agent is running on the local workstation and the relevant key is added:

Start SSH agent
```$(eval ssh-agent)```

Add the ssh key to ssh-agent
```ssh-add *ssh-key-name*```

Establish the SSH tunnel (example only, see the CloudFormation template output for actual command):

```
ssh -L 7474:test-121022-nlb-a741fcfff76a03.elb.us-east-1.amazonaws.com:7474 -L 7687:test-121022-nlb-a741fcfff76a03.elb.us-east-1.amazonaws.com:7687 -A ec2-user@public_ip_of_bastion
```

Once the tunnel has been established, neo4j can be accessed via a web browser at [http://localhost:7474].  The database username will be ```neo4j``` and the password can be found in the ```deploy.sh``` script 


## AWS Diagram

The following diagram depicts the environment which is created by this cloudformation template:

![](neo4j-aws-3-node-private.png?raw=true)
