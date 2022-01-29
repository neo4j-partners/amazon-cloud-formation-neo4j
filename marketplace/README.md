# marketplace
This template is used by the Neo4j AWS Marketplace offer. It is not intended to be used outside the marketplace. 

Unless you are a Neo4j employee updating the Azure Marketplace listing, you probably want to be using either the Marketplace listing itself or [simple](../simple).

# Updating the listing
If you're a Neo4j employee updating the AWS Marketplace listing, you're first going to have to get a new AMI ID.  To do that...

CFT deploys in AWS Marketplace aren't self service.  At some point that might change.  So, next up is updating the product load form.  That's stored [here](https://docs.google.com/spreadsheets/d/1Nmpw3etZX7xj6nQgS5w3K2B-i0gJevdQ/edit?usp=sharing&ouid=115505246243451814800&rtpof=true&sd=true).  Note that AWS will almost certainly continue to rev the product load form.  So, you might periodically be forced to grab a new copy from to publisher portal.

Things you'll definitely want to update in the product load from are:

* AMI ID
* CFT template link
* Version of the offer

We should really investigate if AWS has any APIs we could use to automate this.  However given the lack of portal self service, I suspect not.

Once the product load form is all up to date, you'll just need to resubmit it in the portal [here](https://aws.amazon.com/marketplace/management/offers).
