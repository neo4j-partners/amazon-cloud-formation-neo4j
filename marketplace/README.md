# marketplace
This template is used by the Neo4j AWS Marketplace offer.  You can deploy it [here](https://aws.amazon.com/marketplace/pp/prodview-akmzjikgawgn4).  It can also be useful to fork this repo and customize the template to meet your needs.

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
    cd marketplace

## Creating a Stack
The AWS word for a deployment is a stack.  [deploy.sh](deploy.sh) is a helper script to deploy a stack.  Take a look at it and modify any variables, then run it as:

    ./deploy.sh <STACK_NAME>

When complete you can access the Neo4j Browser at the Neo4jBrowserURL given in the stack outputs.

## Deleting a Stack
To delete your deployment you can either run the command below or use the GUI in the web console [here](https://console.aws.amazon.com/cloudformation/home).

    aws cloudformation delete-stack --stack-name <STACK_NAME>

## Debugging
If the Neo4j Browser isn't coming up, there's a good chance something isn't right in your deployment.  One thing to investigate is the cloud-init logs.  `/var/log/cloud-init-output.log` is probably the best starting point.  If that looks good, the next place to check out is `/var/log/neo4j/debug.log`.

## Updating the AMI
If you're a Neo4j employee updating the AWS Marketplace listing, you're first going to have to get a new AMI ID.  First off, make extra special sure you do this work in the AWS account associated with our publisher.  It's seems AMI sharing across accounts has bugs, so you want to avoid needing to use that. 

We've been using the AMI builder with the [build.sh](build.sh) script in this directory.  Marketplace has a requirement to disable password access to Marketplace VMs even though the platform images have it enabled.  The builder creates an AMI in a special builder account.  We've had to then copy that AMI to the publisher account manually because something in the Marketplace pipeline is broken.  This process seems like it's changing daily, so it's probably best to check with the AWS Marketplace operations people as you work through the process.

You'll then want to take the AMI ID from that and stuff it both into the CFT and the product load form.  In addition, login to [Marketplace Portal](https://aws.amazon.com/marketplace/management/manage-products/?#/share) and add the AMI.

## Updating the Marketplace Listing
CFT deploys in AWS Marketplace aren't self service.  At some point that might change.  So, next up is updating the product load form.  That's stored [here](https://docs.google.com/spreadsheets/d/1Nmpw3etZX7xj6nQgS5w3K2B-i0gJevdQ/edit?usp=sharing&ouid=115505246243451814800&rtpof=true&sd=true).  Note that AWS will almost certainly continue to rev the product load form.  So, you might periodically be forced to grab a new copy from to publisher portal.

You'll defintely want to update the version ID in the product load form.  You will need to update the AMI ID as well, if you built a new one.

Once the product load form is all up to date, you'll just need to resubmit it in the portal [here](https://aws.amazon.com/marketplace/management/offers).

There is currently no API for any of this, so the process has to be manual.  If we didn't have a CFT we could automate.
