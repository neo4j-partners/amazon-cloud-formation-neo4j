# simple
This is an Amazon CloudFormation Template (CFT) that deploys Neo4j Enterprise on AWS.  It sets up Neo4j Graph Database, Graph Data Science and Bloom.

# Instructions
To deploy this template from the command line, follow these instructions.

## Environment Setup
First we need to install and configure the AWS CLI.  Follow the instructions Amazon provides [here](http://docs.aws.amazon.com/cli/latest/userguide/installing.html).  Basically all you need to do is:

    pip install --upgrade --user awscli
    aws configure

You can confirm the CLI is working properly by running:

    aws ec2 describe-account-attributes

If you don't have a key, you'll also need to create one.  That can be done with these commands:

    REGION=`aws configure get region`
    aws ec2 create-key-pair \
      --region ${REGION} \
      --key-name ${KEY_NAME} \
      --query 'KeyMaterial' \
      --output text > ${KEY_FILENAME}
    chmod 600 ${KEY_FILENAME}
    echo "Key saved to ${KEY_FILENAME}"

You should check ~/.ssh/ to see that key is saved.

    cd ~/.ssh
    ls -la

You shouold see a file like this:

    -rw-------   1 <name> <admin> 1679 Mar 29 14:09 neo4j-us-west-1.pem
    
Then you'll want to clone this repo.  You can do that with the command:

    git clone https://github.com/neo4j-partners/amazon-cloud-formation-neo4j.git
    cd amazon-cloud-formation-neo4j
    cd simple

## Creating a Stack
The AWS word for a deployment is a stack.  [deploy.sh](deploy.sh) is a helper script to deploy a stack.  Take a look at it and modify any variables, then run it as:

    ./deploy.sh <STACK_NAME>

When complete you can access the Neo4j console on port 7474 of any node.

## Deleting a Stack
To delete your deployment you can either run the command below or use the GUI in the web console [here](https://console.aws.amazon.com/cloudformation/home).

    aws cloudformation delete-stack --stack-name <STACK_NAME>

## Debugging
If the Neo4j Browser isn't coming up, there's a good chance something isn't right in your deployment.  One thing to investigate is the cloud-init logs.  `/var/log/cloud-init-output.log` is probably the best starting point.  If that looks good, the next place to check out is `/var/log/neo4j/debug.log`.
