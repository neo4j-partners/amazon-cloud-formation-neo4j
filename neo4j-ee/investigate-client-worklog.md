# Investigate Client Worklog

Date: 2026-05-09

## Summary

The sample app failed because it was deployed against a single-server EE stack with `neo4j+s`, which makes the Neo4j Python driver fetch routing information before opening the first session. The live stack then exposed a second issue: the ACM certificate is an imported self-issued certificate for `neo4j.test.local`, so Lambda's system trust store could not validate it.

Permanent fix:

- Replaced the Bash deployer with `sample-private-app/deploy-sample-private-app.py`, a `uv` Python script using boto3.
- Deleted `sample-private-app/deploy-sample-private-app.sh`; no wrapper remains.
- Updated docs to call `uv run deploy-sample-private-app.py`.
- For single-server stacks, the sample now uses direct Bolt mode.
- For ACM `IMPORTED` or `PRIVATE` certificates, the deployer packages a PEM trust bundle from ACM and the Lambda uses `neo4j.TrustCustomCAs`.
- The Lambda skips routing-table inspection in direct Bolt mode.

Live fix:

- The original app stack `neo4j-sample-private-app-tls-validate` was already in `DELETE_IN_PROGRESS`, blocked on Lambda function deletion.
- Deployed fixed app stack `neo4j-sample-private-app-tls-validate-fixed`.
- Invoked the fixed app successfully. It returned Enterprise Edition, one available server, and the fintech graph sample.

## Commands

### Repository inspection

Command:

```bash
pwd && rg --files -g '!*lambda.zip' | rg 'sample-private-app|deploy-sample|template|py$|sh$|md$'
```

Summary: Confirmed the repo root and found the sample app deploy script, Lambda handler, template, README, and related docs.

Command:

```bash
git status --short
```

Summary: Found an already dirty worktree. Several files outside this change were modified before this investigation.

Command:

```bash
sed -n '1,240p' sample-private-app/lambda/handler.py
sed -n '1,260p' sample-private-app/deploy-sample-private-app.sh
sed -n '1,260p' sample-private-app/sample-private-app.template.yaml
sed -n '1,220p' sample-private-app/README.md
```

Summary: Read the handler, Bash deployer, CloudFormation template, and README. The handler built a `neo4j+s://<advertised-dns>:7687` driver and ran writes immediately, which requires routing discovery.

Command:

```bash
sed -n '260,560p' sample-private-app/deploy-sample-private-app.sh
sed -n '220,520p' sample-private-app/sample-private-app.template.yaml
```

Summary: Read the rest of the deployer and template. The deployer generated helper scripts and passed only `neo4j+s` or `neo4j+ssc` to CloudFormation.

### AWS investigation

Command:

```bash
rg -n "advertised|routing|server\\.bolt|dbms\\.routing|BoltScheme|bolt\\+s|neo4j\\+s" templates sample-private-app deploy.py README.md docs validate-private
```

Summary: Confirmed the platform config sets `server.bolt.advertised_address` and docs assume `neo4j+s` for routed cluster clients.

Command:

```bash
aws logs tail /aws/lambda/neo4j-sample-private-app-tls-validate --region us-east-2 --since 30m --format short
```

Summary: CloudWatch logs showed `ServiceUnavailable: Unable to retrieve routing information` during `session.run(_MERGE_FINTECH)`.

Command:

```bash
aws lambda get-function-configuration --region us-east-2 --function-name neo4j-sample-private-app-tls-validate --query '{Runtime:Runtime,Timeout:Timeout,VpcConfig:VpcConfig,Environment:Environment.Variables,LastModified:LastModified,State:State,LastUpdateStatus:LastUpdateStatus}' --output json
```

Summary: Confirmed the deployed Lambda had `NEO4J_BOLT_SCHEME=neo4j+s`, a single private subnet, and the expected SSM and Secrets Manager environment variables.

Command:

```bash
aws ssm get-parameters-by-path --region us-east-2 --path /neo4j-ee/tls-validate --recursive --query 'Parameters[].{Name:Name,Value:Value}' --output table
```

Summary: Confirmed the EE stack contract. `advertised-dns` is `neo4j.test.local`; only one private subnet parameter exists, matching a single-server stack.

Command:

```bash
aws lambda update-function-configuration --region us-east-2 --function-name neo4j-sample-private-app-tls-validate --environment 'Variables={NEO4J_SSM_ADVERTISED_DNS_PATH=/neo4j-ee/tls-validate/advertised-dns,NEO4J_BOLT_SCHEME=bolt+s,NEO4J_SECRET_ARN=arn:aws:secretsmanager:us-east-2:159878781974:secret:neo4j/tls-validate/password-Z2MDlr}' --query '{FunctionName:FunctionName,LastUpdateStatus:LastUpdateStatus,Environment:Environment.Variables}' --output json
```

Summary: Changed the live Lambda to direct `bolt+s` to test whether the routing failure was specific to `neo4j+s`.

Command:

```bash
aws lambda wait function-updated --region us-east-2 --function-name neo4j-sample-private-app-tls-validate
```

Summary: Waited for the Lambda environment update to complete.

Command:

```bash
./invoke.sh
```

Summary: The routing error was replaced by TLS verification failure. The driver could resolve and reach `neo4j.test.local:7687`, but could not validate the certificate.

Command:

```bash
cat sample-private-app/lambda/requirements.txt
python3 -c 'import neo4j, inspect; print(neo4j.__version__); print([n for n in dir(neo4j) if "Trust" in n or "Cert" in n])'
aws acm describe-certificate --region us-east-2 --certificate-arn arn:aws:acm:us-east-2:159878781974:certificate/f581ce4b-456b-4e48-b0ae-87a7d6ccc96b --query 'Certificate.{DomainName:DomainName,SubjectAlternativeNames:SubjectAlternativeNames,Type:Type,Issuer:Issuer,Status:Status,NotAfter:NotAfter}' --output json
```

Summary: Confirmed the Lambda uses `neo4j>=6,<7`, local installed driver version was 6.2.0, and the driver supports `TrustCustomCAs`. ACM reported the certificate as `IMPORTED`, issuer `neo4j.test.local`, SAN `neo4j.test.local`.

Command:

```bash
python3 -c 'import neo4j, inspect; print(inspect.signature(neo4j.GraphDatabase.driver)); print(neo4j.TrustCustomCAs); print(inspect.signature(neo4j.TrustCustomCAs))'
rg -n "trusted_certificates|TrustCustomCAs|encrypted|TRUST" sample-private-app/lambda/neo4j -g '*.py'
sed -n '180,260p' sample-private-app/lambda/neo4j/_sync/driver.py
sed -n '60,130p' sample-private-app/lambda/neo4j/_conf.py
```

Summary: Confirmed custom CA config must use base `bolt` or `neo4j` schemes with `encrypted=True` and `trusted_certificates=TrustCustomCAs(...)`.

Command:

```bash
aws acm get-certificate --region us-east-2 --certificate-arn arn:aws:acm:us-east-2:159878781974:certificate/f581ce4b-456b-4e48-b0ae-87a7d6ccc96b --query '{Certificate:Certificate,CertificateChain:CertificateChain}' --output json
```

Summary: Confirmed ACM can return a PEM certificate chain suitable for packaging as a custom trust bundle.

### Implementation and verification

Command:

```bash
bash -n sample-private-app/deploy-sample-private-app.sh
python3 -m py_compile sample-private-app/lambda/handler.py
git diff -- sample-private-app/lambda/handler.py sample-private-app/deploy-sample-private-app.sh sample-private-app/sample-private-app.template.yaml
```

Summary: Initial Bash patch and Lambda handler compiled, but the deployer became too hard to maintain due to shell quoting and embedded Python.

Command:

```bash
uv run sample-private-app/deploy-sample-private-app.py --help
```

Summary: Verified the new `uv` Python deployer argument parser.

Command:

```bash
rg -n "deploy-sample-private-app\\.sh|Run ./deploy-sample|Redeploy with ./deploy-sample|aws cloudformation deploy" README.md docs sample-private-app -g '*.md' -g '*.sh' -g '*.py'
```

Summary: Verified old deploy command references were removed from docs and helper messages.

Command:

```bash
python3 -m py_compile sample-private-app/deploy-sample-private-app.py sample-private-app/lambda/handler.py
```

Summary: Verified the new deployer and Lambda handler compile.

Command:

```bash
uv run deploy-sample-private-app.py tls-validate
```

Summary: First run failed during packaging because `uv` script environments do not include `pip` in `sys.executable`. The deployer was changed to use `uv pip install --target`.

Command:

```bash
uv pip install --help | sed -n '1,120p'
```

Summary: Confirmed `uv pip install` supports `--target`, which is suitable for Lambda packaging.

Command:

```bash
uv run deploy-sample-private-app.py tls-validate
```

Summary: Packaging and S3 upload succeeded. CloudFormation update failed because `neo4j-sample-private-app-tls-validate` was in `DELETE_IN_PROGRESS`.

Command:

```bash
aws cloudformation describe-stacks --region us-east-2 --stack-name neo4j-sample-private-app-tls-validate --query 'Stacks[0].{Status:StackStatus,Reason:StackStatusReason}' --output json
aws cloudformation describe-stack-events --region us-east-2 --stack-name neo4j-sample-private-app-tls-validate --query 'StackEvents[0:12].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' --output table
```

Summary: Confirmed the original app stack was deleting and blocked on Lambda function deletion; security group rules were already deleted.

Command:

```bash
ps -ax | rg 'deploy-sample-private-app.py|uv run deploy-sample'
kill 23442 23453
```

Summary: Stopped the deploy process that was waiting for the original stack deletion so no background waiter remained.

Command:

```bash
uv run deploy-sample-private-app.py tls-validate --suffix fixed
```

Summary: Deployed `neo4j-sample-private-app-tls-validate-fixed` successfully. The deploy used `Bolt Scheme: bolt` and packaged `lambda/neo4j-ca.pem` from the imported ACM certificate.

Command:

```bash
./invoke.sh
```

Summary: Invocation succeeded. Response included `"bolt_scheme": "bolt"`, `"trusted_ca": true`, `"edition": "enterprise"`, one available server, and the sample graph rows.

Command:

```bash
aws cloudformation describe-stacks --region us-east-2 --stack-name neo4j-sample-private-app-tls-validate --query 'Stacks[0].StackStatus' --output text
aws cloudformation describe-stacks --region us-east-2 --stack-name neo4j-sample-private-app-tls-validate-fixed --query 'Stacks[0].StackStatus' --output text
```

Summary: Original app stack remained `DELETE_IN_PROGRESS`; fixed suffixed app stack was `CREATE_COMPLETE`.

Command:

```bash
find sample-private-app/lambda -maxdepth 1 -name '.lock' -o -name 'neo4j-ca.pem'
```

Summary: Found generated packaging artifacts. The deployer now excludes/removes `.lock` and removes the packaged CA from the source tree after zipping.

### Retest canonical sample app

Command:

```bash
./invoke.sh
aws cloudformation describe-stacks --region us-east-2 --stack-name neo4j-sample-private-app-tls-validate-fixed --query 'Stacks[0].StackStatus' --output text
aws cloudformation describe-stacks --region us-east-2 --stack-name neo4j-sample-private-app-tls-validate --query 'Stacks[0].StackStatus' --output text
```

Summary: `invoke.sh` was missing because the canonical app stack had been deleted and the generated helper script was not present locally. The fixed suffixed stack was still `CREATE_COMPLETE`. The original canonical stack no longer existed, so the canonical stack name was available again.

Command:

```bash
uv run deploy-sample-private-app.py tls-validate
```

Summary: Recreated the canonical sample app stack `neo4j-sample-private-app-tls-validate`. The deployer selected `Bolt Scheme: bolt`, packaged the ACM imported certificate as `neo4j-ca.pem`, uploaded Lambda zip version `TBqrfbJtlOxWmtKZ.eOmYVDM6eWfbTzO`, wrote `.deploy/sample-private-app-tls-validate.json`, and regenerated `invoke.sh` and `validate.sh`.

Command:

```bash
./invoke.sh
```

Summary: Invocation succeeded against the canonical app stack. Response included `"bolt_scheme": "bolt"`, `"trusted_ca": true`, `"edition": "enterprise"`, zero newly created nodes/relationships because the MERGE data already existed, the three graph sample rows, and one `Available` server.

Command:

```bash
aws cloudformation describe-stacks --region us-east-2 --stack-name neo4j-sample-private-app-tls-validate --query 'Stacks[0].StackStatus' --output text
cat .deploy/sample-private-app-tls-validate.json
find sample-private-app/lambda -maxdepth 1 -name '.lock' -o -name 'neo4j-ca.pem' -o -name 'lambda.zip'
```

Summary: Confirmed the canonical app stack is `CREATE_COMPLETE`, the local deploy JSON points to `neo4j-sample-private-app-tls-validate`, and no generated packaging artifacts remained in `sample-private-app/lambda`.
