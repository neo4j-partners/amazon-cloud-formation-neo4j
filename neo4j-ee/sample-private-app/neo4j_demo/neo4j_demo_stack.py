import aws_cdk as cdk
from aws_cdk import (
    aws_ec2 as ec2,
    aws_iam as iam,
    aws_lambda as lambda_,
    aws_logs as logs,
    aws_secretsmanager as sm,
)
from constructs import Construct


class Neo4jDemoStack(cdk.Stack):
    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        def require_context(key: str) -> str:
            val = self.node.try_get_context(key)
            if not val:
                raise ValueError(f"CDK context '{key}' is required. Run via deploy-sample-private-app.sh.")
            return val

        vpc_id = require_context("vpcId")
        external_sg_id = require_context("externalSgId")
        password_secret_arn = require_context("passwordSecretArn")
        neo4j_stack = require_context("neo4jStack")
        vpc_endpoint_sg_id = require_context("vpcEndpointSgId")
        ssm_prefix = f"/neo4j-ee/{neo4j_stack}"

        vpc = ec2.Vpc.from_lookup(self, "Neo4jVpc", vpc_id=vpc_id)

        neo4j_external_sg = ec2.SecurityGroup.from_security_group_id(
            self, "Neo4jExternalSG", external_sg_id, mutable=True
        )

        endpoint_sg = ec2.SecurityGroup.from_security_group_id(
            self, "VpcEndpointSG", vpc_endpoint_sg_id, mutable=True
        )

        lambda_sg = ec2.SecurityGroup(
            self,
            "Neo4jLambdaSG",
            vpc=vpc,
            description="Egress-only SG for Neo4j demo Lambda",
            allow_all_outbound=False,
        )
        lambda_sg.add_egress_rule(
            peer=neo4j_external_sg,
            connection=ec2.Port.tcp(7687),
            description="Bolt to Neo4j NLB",
        )
        lambda_sg.add_egress_rule(
            peer=endpoint_sg,
            connection=ec2.Port.tcp(443),
            description="HTTPS to VPC interface endpoints",
        )
        endpoint_sg.add_ingress_rule(
            peer=lambda_sg,
            connection=ec2.Port.tcp(443),
            description="Allow Lambda SG to reach VPC interface endpoints",
        )
        neo4j_external_sg.add_ingress_rule(
            peer=lambda_sg,
            connection=ec2.Port.tcp(7687),
            description="Allow Lambda Bolt to NLB",
        )

        password_secret = sm.Secret.from_secret_complete_arn(
            self, "Neo4jPasswordSecret", password_secret_arn
        )

        fn_role = iam.Role(
            self,
            "Neo4jDemoFunctionRole",
            assumed_by=iam.ServicePrincipal("lambda.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name(
                    "service-role/AWSLambdaVPCAccessExecutionRole"
                )
            ],
        )
        fn_role.add_to_policy(
            iam.PolicyStatement(
                actions=["ssm:GetParameter"],
                resources=[
                    f"arn:aws:ssm:{self.region}:{self.account}:parameter{ssm_prefix}/*"
                ],
            )
        )
        password_secret.grant_read(fn_role)

        fn_log_group = logs.LogGroup(
            self,
            "Neo4jDemoFunctionLogGroup",
            retention=logs.RetentionDays.ONE_MONTH,
            removal_policy=cdk.RemovalPolicy.DESTROY,
        )

        demo_fn = lambda_.Function(
            self,
            "Neo4jDemoFunction",
            runtime=lambda_.Runtime.PYTHON_3_13,
            handler="handler.lambda_handler",
            code=lambda_.Code.from_asset("lambda"),
            role=fn_role,
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PRIVATE_WITH_EGRESS),
            security_groups=[lambda_sg],
            memory_size=512,
            timeout=cdk.Duration.seconds(30),
            environment={
                "NEO4J_SSM_NLB_PATH": f"{ssm_prefix}/nlb-dns",
                "NEO4J_SECRET_ARN": password_secret_arn,
            },
            log_group=fn_log_group,
            logging_format=lambda_.LoggingFormat.JSON,
            application_log_level_v2=lambda_.ApplicationLogLevel.INFO,
            tracing=lambda_.Tracing.ACTIVE,
        )

        fn_url = demo_fn.add_function_url(
            auth_type=lambda_.FunctionUrlAuthType.AWS_IAM,
        )

        cdk.CfnOutput(self, "FunctionUrl", value=fn_url.url)
        cdk.CfnOutput(self, "FunctionArn", value=demo_fn.function_arn)
