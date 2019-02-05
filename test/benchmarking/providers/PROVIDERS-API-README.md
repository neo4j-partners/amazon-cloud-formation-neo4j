# Benchmarking Providers

A provider is just a directory with some shell scripts that provides the ability to
create and delete a Neo4j stack, maybe with some parameters.

Different providers may be different public clouds, or different deployment topologies.

Providers can be passed to the run-benchmark script, which uses them to create/delete.

# Provider API

Simple - 

* Must provide a create-cluster.sh script.
* Must provide a delete-cluster.sh script.

## Creating Clusters

The create-cluster.sh script must output the following (but can output anything else):

RUN_ID=blahblah
NEO4J_IP=x.y.z.a
NEO4J_PASSWORD=foobar
STACK_NAME=sometoken

This script requires no arguments, but providers may require arguments specific to that
provider as necessary.

A run ID is any unique ID token.  The script should not return until the stack is working,
and accessible under $NEO4J_IP and $NEO4J_PASSWORD.

## Deleting Clusters

The delete-cluster.sh script always takes a STACK_NAME as an argument, and destroys the 
cluster.  The STACK_NAME is some token that the provider needs to destroy the cluster.
What this token is varies by provider (AWS vs. GCP for example)