# Benchmarking Providers

A provider is just a directory with some shell scripts that provides the ability to
create and delete a Neo4j stack, maybe with some parameters.

Different providers may be different public clouds, or different deployment topologies.

Providers can be passed to the run-benchmark script, which uses them to create/delete.

# Provider API

Simple - 

* Must provide a create.sh script.
* Must provide a delete.sh script.

This lets you implement a provider in whatever tech you want, python, go, whatever.

## Creating Clusters

The create.sh script must output the following (but can output anything else):

RUN_ID=blahblah
NEO4J_URI=bolt+routing://x.y.z.a
NEO4J_PASSWORD=foobar
STACK_NAME=sometoken

This script requires no arguments, but providers may require arguments specific to that
provider as necessary.

A run ID is any unique ID token.  The script should not return until the stack is working,
and accessible under $NEO4J_URI and $NEO4J_PASSWORD.

By outputting NEO4J_URI, the provider may select host, port, and driver (e.g. routing)
that should be used for the benchmark.

## Deleting Clusters

The delete.sh script always takes a STACK_NAME as an argument, and destroys the 
cluster.  The STACK_NAME is some token that the provider needs to destroy the cluster.
What this token is varies by provider (AWS vs. GCP for example)

## Instance Requirements

- Must be accessible by bolt, with the username/password provided.
- Must be a non-default password, so the benchmark is not required to change it before doing writes.
- Must provide minimum 50GB of disk, so that write-heavy workloads have space to work with and the
benchmark doesn't fail due to uninteresting reasons (no more disk)

Anything not mentioned above is left up to the provider to decide/configure.