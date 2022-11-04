# AWS Network Load Balancer with SSL Termination

## Description

This custom CloudFormation Template (CFT) provides a method of deploying Neo4j with a secure (SSL/TLS) connection between the client and the Network Load Balancer.

## Prerequisites

There are two vital prerequisites which must be met prior to deploying this template:

1) You have administrative access to an internet Domain and are able to create DNS entries against (hereafter known as "SSLDomain")

2) You have created (or are able to create) a TLS Certificate in AWS Certificate Manager, pointing to SSLDomain

## Installation Instructions

_These steps assume that the prerequisites listed above are met.  In this example, the domain edrandall.uk will be used._

### 1) Request a public TLS certificate from Amazon Certificate Manager
Go to AWS Certificate Manager and select a new public certificate
![](images/request-public-certificate.png?raw=true)

### 2) Enter your SSLDomain and leave the "DNS Validation" box selected.
![](images/request-certificate.png?raw=true)


![](images/cert-issued.png?raw=true)

![](images/cert-pending-validation.png?raw=true)
![](images/crt-config?raw=true)
![](images/cname-dns-ownership?raw=true)
![](images/create-cns-for-nlb.png?raw=true)
![](images/neo4j-behind-ssl?raw=true)
![](images/no-certificates.png?raw=true)
![](images/outputs.png?raw=true)








