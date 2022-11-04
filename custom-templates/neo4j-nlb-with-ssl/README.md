# AWS Network Load Balancer with SSL Termination

## Description

This custom CloudFormation Template (CFT) provides a method of deploying Neo4j with a secure (SSL/TLS) connection between the client and the Network Load Balancer.  All traffic after (or 'south') of the NLB will remain unencrypted, as will traffic between the Neo4j EC2 instances.

## Prerequisites

There are two vital prerequisites which must be met prior to deploying this template:

1) You have administrative access to an internet Domain and are able to create DNS entries against (hereafter known as "SSLDomain")

2) You have created (or are able to create) a TLS Certificate in AWS Certificate Manager, pointing to SSLDomain

## Installation Instructions

_These steps assume that the prerequisites listed above are met.  In this example, the domain edrandall.uk will be used._

### Stage 1 - SSL Certificate and DNS Configuration

#### 1) Request a public TLS certificate from Amazon Certificate Manager
![](images/request-certificate.png?raw=true)

#### 2) Enter your SSLDomain and leave the "DNS Validation" box selected.
![](images/request-public-certificate.png?raw=true)

#### 3) Your new certificate will be created and show as "pending validation"
![](images/cert-pending-validation.png?raw=true)

#### 4) Click the Certificate ID and take note of the CNAME which will need to be created in your own DNS to 'prove' to AWS that you own and control this domain.

#### 5) In your own provider's console, create the CNAME.
![](images/cname-dns-ownership.png?raw=true)

#### 6) After a few minutes (could take longer depending on DNS propogation speeds) your new certificate should change status to "Issued"
![](images/cert-issued.png?raw=true)

---

![](images/crt-config.png?raw=true)
![](images/create-cns-for-nlb.png?raw=true)
![](images/neo4j-behind-ssl?raw=true)
![](images/outputs.png?raw=true)








