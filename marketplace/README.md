# marketplace
This template is used by the Neo4j AWS Marketplace offer. It is not intended to be used outside the marketplace. 

Unless you are a Neo4j employee updating the Azure Marketplace listing, you probably want to be using either the Marketplace listing itself or [simple](../simple).

# Updating the AMI
If you're a Neo4j employee updating the AWS Marketplace listing, you're first going to have to get a new AMI ID. To do that, first grab the latest Amazon Linux 2 AMI ID:

    aws ssm get-parameters --names /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2 --region us-east-1 

You'll want to take the AMI ID and use it in this command:

    aws ec2 copy-image \
        --source-region us-east-1 \
        --source-image-id ami-01893222c83843146 \
        --name "Neo4j Enterprise Edition"

You'll then want to take the AMI ID from that and stuff it both into the CFT and the product load form.

There's also some required magic to make the AMI accessible to the AWS Marketplace people [here](https://docs.aws.amazon.com/marketplace/latest/userguide/ami-single-ami-products.html#single-ami-marketplace-ami-access).  That's already been done for the account, so shouldn't have to be done again as long as we continue to use the same account.

# Updating the Marketplace Listing
CFT deploys in AWS Marketplace aren't self service.  At some point that might change.  So, next up is updating the product load form.  That's stored [here](https://docs.google.com/spreadsheets/d/1Nmpw3etZX7xj6nQgS5w3K2B-i0gJevdQ/edit?usp=sharing&ouid=115505246243451814800&rtpof=true&sd=true).  Note that AWS will almost certainly continue to rev the product load form.  So, you might periodically be forced to grab a new copy from to publisher portal.

Things you'll definitely want to update in the product load from are:

* AMI ID
* CFT template link
* Version of the offer

We should really investigate if AWS has any APIs we could use to automate this.  However given the lack of portal self service, I suspect not.

Once the product load form is all up to date, you'll just need to resubmit it in the portal [here](https://aws.amazon.com/marketplace/management/offers).
