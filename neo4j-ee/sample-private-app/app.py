#!/usr/bin/env python3
import os
import aws_cdk as cdk
from neo4j_demo.neo4j_demo_stack import Neo4jDemoStack

app = cdk.App()

stack_name = app.node.try_get_context("cdkStackName") or "neo4j-cdk-demo"

# Region is passed explicitly as context by deploy-sample-private-app.sh so the
# VPC lookup uses the correct region regardless of the shell environment.
region = (
    app.node.try_get_context("region")
    or os.environ.get("CDK_DEFAULT_REGION")
    or os.environ.get("AWS_DEFAULT_REGION")
)
account = os.environ.get("CDK_DEFAULT_ACCOUNT")

if not region:
    raise ValueError("Region not set. Pass -c region=<region> or export CDK_DEFAULT_REGION.")
if not account:
    raise ValueError("CDK_DEFAULT_ACCOUNT not set. Export it before calling cdk deploy.")

Neo4jDemoStack(
    app,
    stack_name,
    stack_name=stack_name,
    env=cdk.Environment(account=account, region=region),
)

app.synth()
