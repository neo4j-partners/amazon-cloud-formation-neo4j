Subject: Questions for the Neo4j Agent Memory AWS Marketplace listing

Hello,

I have a few questions about setting up the Neo4j Agent Memory service on AWS Marketplace.

**Pricing**

- What are we going to charge?
- Will pricing be per CPU, or what will the scale be? Other options include per agent, per memory operation, per GB stored, or a flat tier.
- Do we want a free trial or a free tier?
- Will we offer annual contracts, pay-as-you-go, or both?
- Do we plan to support private offers and channel partner offers for negotiated deals?

**Licensing**

- What is the licensing going to be?
- Will we use the AWS Standard Contract for Marketplace, or do we need a custom EULA?
- What is the refund policy?

**Support**

- What is support?
- Which support tiers will we offer, and what are the response times?
- Who on our side owns support for Marketplace customers?

**Additional items for the AWS Marketplace setup**

- **Product type:** We need to decide whether this ships as SaaS, a container, or an AMI. SaaS is the likely fit for a hosted service.
- **Metering:** We need to define the pricing dimensions that the service reports to AWS. For SaaS, this means integrating the Metering Service or Entitlement Service APIs.
- **SaaS integration:** For SaaS, we need a registration landing page that resolves the customer token. We also need to subscribe to the Marketplace SNS notifications for subscribe, unsubscribe, and entitlement changes.
- **Regions:** Which AWS regions will the service run in?
- **Data handling:** Where is customer data stored? What are our data residency and retention commitments?
- **Security and compliance:** Do we have the security documentation that AWS and enterprise buyers will ask for, such as SOC 2?
- **Seller account:** Which AWS account will own the listing? Are tax and banking details already set up for it?
- **Listing content:** Who will write the product description, highlights, and usage instructions? We also need a logo and an architecture diagram.
- **Ownership and timeline:** Who are the owners for pricing, legal, and engineering sign-off? What is the target launch date?

Thanks,
Ryan
