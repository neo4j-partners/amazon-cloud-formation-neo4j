#!/usr/bin/env python3
import os
import aws_cdk as cdk
from neo4j_demo.neo4j_demo_stack import Neo4jDemoStack

app = cdk.App()

stack_name = app.node.try_get_context("cdkStackName") or "neo4j-cdk-demo"

Neo4jDemoStack(
    app,
    stack_name,
    stack_name=stack_name,
    env=cdk.Environment(
        account=os.environ["CDK_DEFAULT_ACCOUNT"],
        region=os.environ["CDK_DEFAULT_REGION"],
    ),
)

app.synth()
