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

`neo4j.template.yaml` is a copy of the original monolithic template kept for reference. It will be removed once the partial-based build is confirmed stable.
