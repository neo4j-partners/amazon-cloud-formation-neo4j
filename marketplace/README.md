# marketplace
This template is used by the Neo4j AWS Marketplace offer. It is not intended to be used outside the marketplace. 

Unless you are a Neo4j employee updating the AWS Marketplace listing, you probably want to be using either the [Marketplace listing](https://aws.amazon.com/marketplace/pp/prodview-akmzjikgawgn4) itself or [simple](../simple).

# Updating the AMI
If you're a Neo4j employee updating the AWS Marketplace listing, you're first going to have to get a new AMI ID.  First off, make extra special sure you do this work in the AWS account associated with our publisher.  It's seems AMI sharing across accounts has bugs, so you want to avoid needing to use that. 

If you're setting up a publisher account for the first time, you'll need to add a role as decribed [here](https://docs.aws.amazon.com/marketplace/latest/userguide/ami-single-ami-products.html#single-ami-marketplace-ami-access).

We've been using Packer and a python script to generate AMIs, copy them across supported regions and update the CFT template accordingly with the new Mappings and Neo4j version. Please read the instructions inside internal-tools directory on how to trigger this process. 
You'll then want to take the AMI ID from that and stuff it into the product load form.  In addition, login to [Marketplace Portal](https://aws.amazon.com/marketplace/management/manage-products/?#/share) and add the AMI.

# Updating the Marketplace Listing
CFT deploys in AWS Marketplace aren't self service.  At some point that might change.  So, next up is updating the product load form.  That's stored [here](https://docs.google.com/spreadsheets/d/1Nmpw3etZX7xj6nQgS5w3K2B-i0gJevdQ/edit?usp=sharing&ouid=115505246243451814800&rtpof=true&sd=true).  Note that AWS will almost certainly continue to rev the product load form.  So, you might periodically be forced to grab a new copy from to publisher portal.

You'll defintely want to update the version ID in the product load form.  You will need to update the AMI ID as well, if you built a new one.

Once the product load form is all up to date, you'll just need to resubmit it in the portal [here](https://aws.amazon.com/marketplace/management/offers).

There is currently no API for any of this, so the process has to be manual.  If we didn't have a CFT we could automate.