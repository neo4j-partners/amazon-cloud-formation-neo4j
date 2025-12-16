# amazon-cloud-formation-neo4j
This repo contains an Amazon CloudFormation Templates (CFT) that deploys Neo4j Enterprise Edition on AWS.   It is the template used in the [Neo4j Enterprise Edition AWS Marketplace listing](https://aws.amazon.com/marketplace/pp/prodview-akmzjikgawgn4).  While deployable through the marketplace, it can also be useful to fork and customize the template to meet your needs.

To deploy this template from the command line, follow these instructions.

## Environment Setup
First we need to install and configure the AWS CLI.  Follow the instructions Amazon provides [here](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html).  Basically all you need to do is:

    curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
    sudo installer -pkg AWSCLIV2.pkg -target /

Once installed, configure with the command:

    aws configure

You can confirm the CLI is working properly by running:

    aws ec2 describe-account-attributes
    
Then you'll want to clone this repo.  You can do that with the command:

    git clone https://github.com/neo4j-partners/amazon-cloud-formation-neo4j.git
    cd amazon-cloud-formation-neo4j

## Creating a Stack
The AWS word for a deployment is a stack.  [deploy.sh](deploy.sh) is a helper script to deploy a stack.  Take a look at it and modify any variables, then run it as:

    ./deploy.sh <STACK_NAME>

When complete you can access the Neo4j Browser at the Neo4jBrowserURL given in the stack outputs.

## Deleting a Stack
To delete your deployment you can either run the command below or use the GUI in the web console [here](https://console.aws.amazon.com/cloudformation/home).

    aws cloudformation delete-stack --stack-name <STACK_NAME>

## Debugging
If the Neo4j Browser isn't coming up, there's a good chance something isn't right in your deployment.  One thing to investigate is the cloud-init logs.  `/var/log/cloud-init-output.log` is probably the best starting point.  If that looks good, the next place to check out is `/var/log/neo4j/debug.log`.
