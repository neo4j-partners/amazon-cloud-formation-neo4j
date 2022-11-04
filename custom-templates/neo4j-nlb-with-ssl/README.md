# AWS Network Load Balancer with SSL Termination

## Description

This custom CloudFormation Template (CFT) provides a method of deploying Neo4j with a secure (SSL/TLS) connection between the client and the Network Load Balancer.

## Prerequisites

There are two vital prerequisites which must be met prior to deploying this template:

1) You have administrative access to an internet Domain and are able to create DNS entries against (hereafter known as "SSLDomain")

2) You have created (or are able to create) a TLS Certificate in AWS Certificate Manager, pointing to SSLDomain


## Installation Instructions

_These steps assume that the prerequisites listed above are met.  In this example, the domain edrandall.uk will be used_









