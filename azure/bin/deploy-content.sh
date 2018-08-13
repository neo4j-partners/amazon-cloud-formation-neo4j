#!/bin/bash
  
s3cmd put -P arm/*.json s3://neo4j-arm/test/

# Results in HTTP location:
# https://s3.amazonaws.com/neo4j-arm/test/
