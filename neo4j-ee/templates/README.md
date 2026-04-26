# templates/

## Convention

| Location | Purpose |
|---|---|
| `templates/` | Generated CloudFormation templates — **do not edit directly** |
| `templates/src/` | Source partials — **edit these** |

To regenerate output templates after editing a partial:

```bash
python templates/build.py
```

## Output templates

| File | Marketplace display name | Target buyer |
|---|---|---|
| `neo4j-public.template.yaml` | Public | Proof of concept, demos, evaluation |
| `neo4j-private.template.yaml` | Private | Production and staging, AWS-managed networking |
| `neo4j-private-existing-vpc.template.yaml` | Private, Existing VPC | Enterprise with pre-existing VPC infrastructure |

## Source partials (src/)

`neo4j.template.yaml` — copy of the current monolithic template, kept as reference for Phase 2 extraction. Once all partials are extracted and the build system is confirmed, this file will be removed.

Phase 2 will introduce individual partial files (`parameters-common.yaml`, `iam.yaml`, `security-groups.yaml`, `userdata.sh`, etc.) as the monolithic template is decomposed. See `marketplace-split-plan.md` for the full plan.
