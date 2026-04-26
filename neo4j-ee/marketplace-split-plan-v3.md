# Neo4j EE — Post-Split Cleanup Plan (v3)

The template split is complete. The three generated templates in `templates/` are now the source of truth. This plan tracks the remaining work to remove the old monolith, wire `deploy.py` to the new templates, and bring supporting tooling and docs into sync.

---

## Phase 1: Cleanup

### Delete `neo4j-ee/neo4j.template.yaml`

The 1,908-line monolithic template is fully superseded by:

- `templates/neo4j-private.template.yaml`
- `templates/neo4j-public.template.yaml`
- `templates/neo4j-private-existing-vpc.template.yaml`

The CI workflow (`validate-templates.yml`) already lints only the new templates. The only remaining reference to the old file is in `deploy.py` (fixed in Phase 2).

### Delete planning artifacts

`marketplace-split-plan.md` and `marketplace-split-plan-v2.md` are complete. Delete both.

### Commit the `deploy.sh` deletion

`deploy.sh` is already staged as deleted in git. Include it in the Phase 1 commit.

---

## Phase 2: Update `deploy.py`

### 2a. Template selection by mode (lines 263–264)

Replace the hardcoded `neo4j.template.yaml` path with a lookup keyed on `--mode`:

```python
TEMPLATE_MAP = {
    "Private":     "templates/neo4j-private.template.yaml",
    "Public":      "templates/neo4j-public.template.yaml",
    "ExistingVpc": "templates/neo4j-private-existing-vpc.template.yaml",
}
```

Update the S3 upload key and `template_url` to use the mapped filename.

### 2b. Add `ExistingVpc` to `--mode` choices

**Recommendation:** extend `--mode` to `["Public", "Private", "ExistingVpc"]` rather than adding a separate `--existing-vpc` flag. Rationale:

- Keeps a single dispatch point — one switch selects both the template and the set of valid parameters.
- `--existing-vpc` as a flag would create an awkward coexistence with `--mode`; callers would need to know which flag takes precedence.
- The additional required args (`--vpc-id`, `--subnet-1`, etc.) are cleanly validated post-parse — a pattern already established by `--allowed-cidr` requiring `--mode Public` to be meaningful.

Add the subnet/VPC args as optional argparse args, then validate after `parse_args()`:

```python
p.add_argument("--vpc-id",   metavar="VPC_ID")
p.add_argument("--subnet-1", metavar="SUBNET_ID")
p.add_argument("--subnet-2", metavar="SUBNET_ID", default="")
p.add_argument("--subnet-3", metavar="SUBNET_ID", default="")
```

Post-parse check:

```python
if args.mode == "ExistingVpc":
    if not args.vpc_id or not args.subnet_1:
        sys.exit("ERROR: --mode ExistingVpc requires --vpc-id and --subnet-1 (--subnet-2 and --subnet-3 required for 3-node).")
    if args.number_of_servers == 3 and not (args.subnet_2 and args.subnet_3):
        sys.exit("ERROR: --mode ExistingVpc with 3 servers requires --subnet-2 and --subnet-3.")
```

Append to `cfn_params` when in ExistingVpc mode:

```python
if args.mode == "ExistingVpc":
    cfn_params += [
        {"ParameterKey": "VpcId",            "ParameterValue": args.vpc_id},
        {"ParameterKey": "PrivateSubnet1Id", "ParameterValue": args.subnet_1},
        {"ParameterKey": "PrivateSubnet2Id", "ParameterValue": args.subnet_2},
        {"ParameterKey": "PrivateSubnet3Id", "ParameterValue": args.subnet_3},
    ]
```

`CreateSSMEndpoint` and `CreateSecretsManagerEndpoint` default to `true` in the template and can be left at default for testing.

### 2c. Remove `DeploymentMode` from `cfn_params` (line 270)

`DeploymentMode` is no longer a parameter in any of the three new templates. Remove this entry from `cfn_params` or CloudFormation will return a parameter validation error.

```python
# Remove this line:
{"ParameterKey": "DeploymentMode", "ParameterValue": args.mode},
```

### 2d. Keep writing `DeploymentMode` to the `.deploy` output file (line 400)

`sample-private-app/deploy-sample-private-app.sh` reads `DeploymentMode` from the `.deploy/` file to gate its own deployment. Keep the write — it is a local output convention, not a CFN parameter.

```python
("DeploymentMode", args.mode),   # keep — read by sample-private-app
```

---

## Phase 3: Supporting tooling and docs

### `sample-private-app/deploy-sample-private-app.sh`

**Guard clause (line 99):** The current check blocks anything that isn't `Private`. `ExistingVpc` is also a private topology and should be allowed:

```bash
# Before
if [ "${DEPLOYMENT_MODE}" != "Private" ]; then

# After
if [ "${DEPLOYMENT_MODE}" != "Private" ] && [ "${DEPLOYMENT_MODE}" != "ExistingVpc" ]; then
```

No other changes needed. The script reads from SSM parameters written by the EE CloudFormation stack, which are unaffected by the template split.

### `validate-private/`

No code changes needed. All commands read from `.deploy/` output files and SSM parameters — neither depends on the template filename or `DeploymentMode` as a CFN parameter.

### `ARCHITECTURE.md`

- **Opening paragraph:** "The `DeploymentMode` parameter controls..." is no longer accurate. Replace with: "Three separate templates cover the supported topologies: private (new VPC), public (new VPC), and private with an existing VPC."
- **Parameters table (line 60):** Remove the `DeploymentMode` row.
- The topology description sections (Private Mode, Public Mode) remain accurate — no changes needed there.

### `README.md`

- The `--mode Public|Private` CLI examples still work as-is — no immediate change needed.
- After Phase 2 lands, add a row for `--mode ExistingVpc` with required `--vpc-id`/`--subnet-*` flags.

### `OPERATOR_GUIDE.md`

No changes needed. Guide covers Private-mode runtime operations only, not template parameters.

### `CLAUDE.md` (project)

Add a short note to the Architecture section about the `templates/` directory: that `templates/build.py` assembles the three output templates from `src/` partials, and that source edits go in `src/` followed by a `build.py` run.

### `teardown.sh`

No changes needed. Reads from `.deploy/` files only — no template filename references.

---

## Change summary

| Item | Phase | Action |
|---|---|---|
| `neo4j-ee/neo4j.template.yaml` | 1 | Delete |
| `marketplace-split-plan.md`, `marketplace-split-plan-v2.md` | 1 | Delete |
| `neo4j-ee/deploy.sh` | 1 | Commit staged deletion |
| `deploy.py` — template selection | 2 | Edit (lines 263–264) |
| `deploy.py` — remove `DeploymentMode` CFN param | 2 | Edit (line 270) |
| `deploy.py` — add `ExistingVpc` mode + subnet args | 2 | Edit |
| `sample-private-app/deploy-sample-private-app.sh` | 3 | Edit (guard clause, line 99) |
| `ARCHITECTURE.md` | 3 | Edit (remove `DeploymentMode` refs) |
| `README.md` | 3 | Edit (add ExistingVpc after Phase 2) |
| `CLAUDE.md` project | 3 | Edit (add `templates/` note) |
| `validate-private/` | 3 | No change |
| `teardown.sh` | 3 | No change |
