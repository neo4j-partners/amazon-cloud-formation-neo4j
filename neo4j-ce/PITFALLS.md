# Neo4j CE CloudFormation - Pitfalls & Lessons Learned

Issues discovered while building the Neo4j Community Edition AWS Marketplace
CloudFormation template against Neo4j **2026.01.3** on Amazon Linux 2023.

---

## 1. Neo4j 2026 Strict Config Validation

**Symptom:** `neo4j-admin dbms set-initial-password` fails with:

```
Failed to read config: Unrecognized setting. No declared setting with name: server.metrics.prefix
```

**Root cause:** Neo4j 2026 enables `server.config.strict_validation.enabled`
by default. Any setting written to `neo4j.conf` that the running edition does
not recognise causes **every** `neo4j-admin` subcommand and `systemctl start
neo4j` to fail — not just the setting itself, but the entire process.

**Settings that were rejected (Community Edition 2026.01):**

| Setting | Why it fails |
|---|---|
| `server.metrics.enabled` | Removed / renamed in 2026 |
| `server.metrics.prefix` | Removed / renamed in 2026 |
| `server.metrics.filter` | Removed / renamed in 2026 |
| `server.metrics.jmx.enabled` | Not available in CE 2026 |
| `server.metrics.csv.enabled` | Not available in CE 2026 |
| `server.metrics.csv.interval` | Not available in CE 2026 |

**Fix:** Removed all custom metrics settings from UserData. The Neo4j
defaults are sufficient for CE.

**Best practice:** Before adding any `neo4j.conf` setting to UserData, verify
it exists in the target Neo4j version and edition by running
`SHOW SETTINGS YIELD name WHERE name CONTAINS '<keyword>'` on a test
instance, or checking the
[Configuration Settings reference](https://neo4j.com/docs/operations-manual/current/configuration/configuration-settings/).

---

## 2. Auth Storage Path Changed in Neo4j 2025+

**Symptom:** Authentication fails (HTTP 401, Bolt "access denied") even
though `set-initial-password` reported success.

**Root cause:** The AMI has `systemctl enable neo4j`, so Neo4j may
auto-start before UserData runs. The original script deleted the legacy auth
file (`/var/lib/neo4j/data/dbms/auth.db`), but Neo4j 2025+ stores
credentials in the **system database** on first start. The stale system
database retained the old default password, and `set-initial-password` only
writes an `auth.ini` seed file — it does not overwrite an existing system
database.

**Fix:** Stop Neo4j and delete all auth-related state before setting the
password:

```bash
systemctl stop neo4j 2>/dev/null || true
rm -rf /var/lib/neo4j/data/dbms/              # auth.ini seed dir
rm -rf /var/lib/neo4j/data/databases/system/  # system database
rm -rf /var/lib/neo4j/data/transactions/system/ # system tx logs
```

**Best practice:** When the AMI pre-enables the Neo4j service, always stop it
and wipe the system database before running `set-initial-password`. This
guarantees the password seed is consumed on the next (first real) start.

---

## 3. CloudFormation Stack Succeeds Even When UserData Fails

**Symptom:** `aws cloudformation wait stack-create-complete` returns success,
but Neo4j is broken. No indication of failure until manual testing.

**Root cause:** Without a `CreationPolicy` on the Auto Scaling Group,
CloudFormation considers the resource complete as soon as the ASG reaches its
desired capacity — regardless of whether the instance's UserData succeeded.

**Fix:** Added a `CreationPolicy` with `ResourceSignal` to the ASG, and a
signaling helper in UserData:

```yaml
Neo4jAutoScalingGroup:
  Type: AWS::AutoScaling::AutoScalingGroup
  CreationPolicy:
    ResourceSignal:
      Count: 1
      Timeout: PT10M
```

```bash
signal_cfn() {
  local status="$1"
  TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id)
  aws cloudformation signal-resource \
    --stack-name "${STACK_NAME}" \
    --logical-resource-id Neo4jAutoScalingGroup \
    --unique-id "$INSTANCE_ID" \
    --status "$status" \
    --region "${REGION}" 2>/dev/null || true
}
trap 'signal_cfn FAILURE' ERR
# ... at the end of UserData:
signal_cfn SUCCESS
```

The instance role also needs `cloudformation:SignalResource` permission.

**Best practice:** Every ASG-backed stack should use `CreationPolicy` +
`ResourceSignal` so CloudFormation fails fast when UserData fails. Pair it
with an `ERR` trap so any non-zero exit triggers a FAILURE signal.

---

## 4. Debugging Blind Without `--disable-rollback`

**Symptom:** Stack creation fails, CloudFormation rolls back and terminates
the instance. There is no way to SSH in or read console output.

**Fix:** Added `--disable-rollback` to `aws cloudformation create-stack` in
`deploy.sh` during development. This preserves the failed instance so you
can:

- Read console output: `aws ec2 get-console-output --instance-id <id>`
- Check `/var/log/neo4j-userdata.log` via SSM Session Manager

**Best practice:** Always use `--disable-rollback` during development.
Remove it before publishing the Marketplace listing or handing the template
to customers.

---

## 5. UserData Logging

**Symptom:** UserData fails silently. Console output only shows the boot log
up to the point of failure — truncated and interleaved with kernel messages.

**Fix:** Added logging at the top of the UserData script:

```bash
exec > >(tee /var/log/neo4j-userdata.log) 2>&1
set -euo pipefail
```

This writes all stdout and stderr to both the console **and** a persistent
log file. Combined with `set -euo pipefail`, any failure is captured with
full context.

**Best practice:** Always log UserData to a file. Use `set -euo pipefail` so
failures are loud and immediate rather than silently cascading.

---

## 6. `internal.` Prefixed Settings Are Unsupported

The `internal.dbms.cypher_ip_blocklist` setting works in Neo4j 2026.01.3 but
carries risk:

- The `internal.` prefix means the setting is **not part of the public API**
  and may be removed or renamed without notice in any future release.
- It survived strict validation in 2026.01, but there is no guarantee it will
  in future patch releases.

**Best practice:** Pin a known-good Neo4j version in the AMI and re-test
after every Neo4j upgrade. If this setting is ever rejected, the SSRF
protection it provides must be replaced with VPC-level network controls
(security groups, NACLs, or VPC endpoints).

---

## 7. APOC Plugin Location Varies by Version

The APOC jar ships with Neo4j but must be copied into the plugins directory.
The source path changed between versions:

| Neo4j Version | APOC Location |
|---|---|
| < 2025.01 | `/var/lib/neo4j/labs/` |
| >= 2025.01 | `/var/lib/neo4j/products/` |

**Fix:** Try both paths with fallback:

```bash
cp /var/lib/neo4j/labs/apoc-*-core.jar /var/lib/neo4j/plugins/ 2>/dev/null || \
  cp /var/lib/neo4j/products/apoc-*-core.jar /var/lib/neo4j/plugins/ 2>/dev/null || true
```

**Best practice:** Keep the fallback pattern so the same template works
across Neo4j versions without modification.

---

## General Best Practices

1. **Validate locally before deploying.**
   `aws cloudformation validate-template` catches YAML/JSON syntax errors.
   `bash -n` catches shell syntax errors in extracted UserData. Neither catches
   Neo4j config errors — those only surface at deploy time.

2. **Use `Fn::Sub` with a variable map** for UserData parameters instead of
   nested `Fn::Join`/`Fn::Select`. It is more readable and less error-prone.

3. **Add an `UpdatePolicy`** to the ASG so stack updates roll instances
   gracefully instead of replacing the ASG wholesale.

4. **Use IMDSv2** (`HttpTokens: required` in the launch template). The
   UserData script's signal helper already uses the token-based IMDSv2 flow.

5. **Test every Neo4j upgrade** in a throwaway stack before updating the
   Marketplace AMI. Config settings are regularly renamed, removed, or moved
   between Community and Enterprise editions.
