# marketplace
This template is used by the Neo4j AWS Marketplace offer. It is not intended to be used outside the marketplace. 

Unless you are a Neo4j employee updating the AWS Marketplace listing, you probably want to be using either the Marketplace listing itself or [simple](../simple).

# Updating the AMI
If you're a Neo4j employee updating the AWS Marketplace listing, you're first going to have to get a new AMI ID.  First off, make extra special sure you do this work in the AWS account associated with our publisher.  It's seems AMI sharing across accounts has bugs, so you want to avoid needing to use that. 

If you're setting up a publisher account for the first time, you'll need to add a role as decribed [here](https://docs.aws.amazon.com/marketplace/latest/userguide/ami-single-ami-products.html#single-ami-marketplace-ami-access).

We've been using the AMI builder with the [build.sh](build.sh) script in this directory.  Marketplace has a requirement to disable password access to Marketplace VMs even though the platform images have it enabled.  The builder creates an AMI in a special builder account.  We've had to then copy that AMI to the publisher account manually because something in the Marketplace pipeline is broken.  This process seems like it's changing daily, so it's probably best to check with the AWS Marketplace operations people as you work through the process.

You'll then want to take the AMI ID from that and stuff it both into the CFT and the product load form.  In addition, login to [Marketplace Portal](https://aws.amazon.com/marketplace/management/manage-products/?#/share) and add the AMI.

# Updating the Marketplace Listing
CFT deploys in AWS Marketplace aren't self service.  At some point that might change.  So, next up is updating the product load form.  That's stored [here](https://docs.google.com/spreadsheets/d/1Nmpw3etZX7xj6nQgS5w3K2B-i0gJevdQ/edit?usp=sharing&ouid=115505246243451814800&rtpof=true&sd=true).  Note that AWS will almost certainly continue to rev the product load form.  So, you might periodically be forced to grab a new copy from to publisher portal.

Things you'll definitely want to update in the product load from are:

* AMI ID
* CFT template link
* Version of the offer

We should really investigate if AWS has any APIs we could use to automate this.  However given the lack of portal self service, I suspect not.

Once the product load form is all up to date, you'll just need to resubmit it in the portal [here](https://aws.amazon.com/marketplace/management/offers).
