# TLS Cleanup Proposal

## Goal

Clean the `bloom` branch so it contains the intended Bloom/GDS, tooling, documentation, and validation improvements without carrying over TLS branch behavior that is not supported by the current templates or `deploy.py` interface.

The cleanup should leave one coherent contract:

- Public, Private, and ExistingVpc templates continue to match their current non-TLS runtime behavior unless TLS is intentionally reintroduced in a separate branch.
- Operator tools, sample app code, and documentation use the fields and ports the templates actually publish.
- Tests catch future drift between docs, deploy flags, generated templates, and validation tools.

## Assumptions

- This branch is not intended to ship the TLS architecture from the source branch.
- The current supported deploy interface is still `deploy.py --tls` for local self-signed Bolt testing, plus the existing CloudFormation parameters `BoltCertificateSecretArn` and `BoltAdvertisedDNS`.
- Private and ExistingVpc Browser access remains HTTP on port `7474` unless a separate TLS implementation changes the templates.
- HTTPS references for AWS APIs, VPC interface endpoints, S3 template URLs, package repositories, and CloudWatch/SSM/Secrets Manager access are not in scope for removal.
- The cleanup should preserve Bloom/GDS license install improvements and the Python migrations for operator scripts.

## Risks

- TLS references are mixed across generated templates, source partials, docs, and new Python tools. Cleaning only docs will leave broken tools.
- Removing all text that contains `TLS`, `cert`, or `https` would remove valid AWS endpoint and package-repository behavior.
- The sample private app previously depended on `AdvertisedDNS` and certificate trust selection. The cleanup intentionally rolled it back to the current platform contract.
- Generated templates must remain in sync with `templates/src` after edits.

## Phase Checklist

### Phase 1: Define The Supported Contract

Status: Complete

Checklist:

- Complete: Confirmed the intended branch contract for Neo4j client access: Browser HTTP on `7474`, Bolt on `7687`, and private stack SSM discovery through `/neo4j-ee/<stack>/nlb-dns`.
- Complete: Kept `deploy.py --tls` as a local self-signed Bolt TLS test flow.
- Complete: Kept baseline CloudFormation Bolt TLS parameters: `BoltCertificateSecretArn` and `BoltAdvertisedDNS`.
- Complete: Marked the extracted TLS branch architecture out of scope: `CertificateArn`, `AdvertisedDNS`, Browser HTTPS on `7473`, public `EnableTLS`, stack-managed DNS aliases, `TrustCustomCAs`, and ACM certificate-type inference.

Validation:

- Complete: `uv run deploy.py --help` matches the remaining README examples and does not expose the removed TLS flags.
- Complete: Unsupported deploy flags were removed from docs.

Notes:

- Default non-TLS outputs remain `.deploy/<stack>.txt`, Browser HTTP on `7474`, Bolt on `7687`, and the private SSM `nlb-dns` contract.
- `deploy.py --tls` now resolves the NLB host from stack outputs, so it no longer depends on a public-mode SSM shim.

### Phase 2: Clean Documentation

Status: Complete

Checklist:

- Complete: Updated `README.md` to remove mandatory TLS claims and unsupported TLS deploy examples.
- Complete: Updated `docs/PUBLIC.md` for Browser `7474`, Bolt `7687`, and optional self-signed Bolt TLS only.
- Complete: Updated `docs/PRIVATE.md` and `docs/PRIVATE-EXISTING-VPC.md` to use Browser `7474`, Bolt `7687`, and `nlb-dns`.
- Complete: Rewrote the TLS architecture content as a narrower optional Bolt TLS section.
- Complete: Updated `docs/marketplace-reference.md` to match the templates.
- Complete: Rewrote `sample-private-app/README.md` around the current SSM contract and topology-based driver mode.
- Complete: Updated Excalidraw source text for public, private, and existing-VPC architecture diagrams.

Validation:

- Complete: Searched docs for removed TLS flags, `7473`, `AdvertisedDNS`, `CertificateArn`, `EnableTLS`, `neo4j+s`, `bolt+s`, `TrustCustomCAs`, and `neo4j-ca`.
- Complete: Remaining matches are retained baseline Bolt TLS parameters or explicit `+ssc` local/self-signed testing references.

### Phase 3: Restore Tooling To The Actual Stack Contract

Status: Complete

Checklist:

- Complete: Updated `browse.py`, `browser-tunnel.py`, and `bolt-tunnel.py` to use the current NLB DNS contract.
- Complete: Restored Browser tunnel behavior to `7474`.
- Complete: Updated validation scripts and package code to avoid `/neo4j-ee/<stack>/advertised-dns`.
- Complete: Default validation uses `bolt` or `neo4j` based on topology, with `+ssc` only when `BoltTlsSecretArn` exists.
- Complete: Removed ACM lookup and certificate-type inference from validation helpers.

Validation:

- Complete: Python compile checks passed for `browse.py`, `deploy.py`, and the changed `validate-private` files.
- Complete: Help checks passed for `browser-tunnel.py`, `bolt-tunnel.py`, and `ssm_tunnel_test.py`.
- Complete: Minimal non-TLS config loading succeeded with no TLS-only fields.

### Phase 4: Clean The Sample Private App

Status: Complete

Checklist:

- Complete: Updated the Lambda to read `/neo4j-ee/<stack>/nlb-dns`.
- Complete: Removed `TrustCustomCAs`, custom CA packaging, `NEO4J_TRUSTED_CA_CERT_FILE`, and ACM certificate lookup logic.
- Complete: Kept topology-based direct `bolt` mode for single-server stacks and routed `neo4j` mode for clusters.
- Complete: Kept resilience Lambda IAM hardening and opt-in behavior.
- Complete: Updated sample app CloudFormation parameters and Lambda environment variables.

Validation:

- Complete: Python compile checks passed for the sample app deployer and Lambda handler.
- Complete: The sample app template no longer requires `BoltScheme`, `TrustedCaCertFile`, or `advertised-dns`.

### Phase 5: Clean Template And Generated Output Drift

Status: Complete

Checklist:

- Complete: Removed `templates/src/stack-config-public.yaml`.
- Complete: Removed public template assembly inclusion for `stack-config-public.yaml`.
- Complete: Reviewed template TLS parameters and kept only baseline optional Bolt TLS support.
- Complete: Regenerated generated templates from source partials.
- Complete: Avoided unrelated Bloom/GDS template changes.

Validation:

- Complete: `python3 templates/build.py --verify` reports all generated templates are up to date.
- Complete: TLS search results in generated templates and source partials are limited to retained `BoltCertificateSecretArn`, `BoltAdvertisedDNS`, and `+ssc` local test behavior.

### Phase 6: Align Deploy Outputs And Tests

Status: Complete

Checklist:

- Complete: Local tools now expect fields currently emitted by `deploy.py`, not extracted TLS branch fields.
- Complete: Kept Bloom/GDS license output fields and did not remove `test_neo4j` license assertions.
- Complete: Removed dependencies on `CertificateArn`, `CertificateType`, `SelfSignedCertificate`, and `AdvertisedDNS`.
- Complete: Ran a lightweight non-TLS config-loading check.

Validation:

- Complete: `rg` checks found no default tool-path dependency on removed TLS fields.
- Complete: `test_neo4j` source search found no removed TLS field dependency.
- Complete: `test_neo4j` Python files compile when pyc output is redirected to `/private/tmp`.

### Phase 7: Final Review And Integration Test Plan

Status: Complete locally; AWS validation pending

Checklist:

- Complete: Reviewed the final diff by category: docs, deployer, templates, sample app, validation tools, and tests.
- Complete: Confirmed customer-facing docs do not claim stack-managed Browser HTTPS, public `EnableTLS`, ACM certificate inference, or stack-managed DNS aliases.
- Complete: Confirmed Python tools no longer require TLS-only fields for default Private or ExistingVpc deployments.
- Complete: Confirmed retained TLS behavior is labeled as optional Bolt TLS and local self-signed testing where applicable.
- Complete: Removed stale local cleanup for the old Lambda CA bundle and corrected remaining HTTPS/TLS labels in the Browser tunnel diagnostic.

Validation:

- Static checks completed so far:
- `python3 templates/build.py --verify`
- Python compile checks for changed Python files
- `bash -n teardown.sh`
- `git diff --check`
- Repository search for unsupported TLS flags and fields
- `uv run deploy.py --help`
- `browser-tunnel.py`, `bolt-tunnel.py`, and `ssm_tunnel_test.py` help paths
- Minimal non-TLS validate-private config load

- AWS smoke tests still recommended:
- Deploy a Public stack and run `test_neo4j`.
- Deploy a Private single-node stack and run `validate-private` plus the sample private app.
- Deploy an ExistingVpc single-node stack using a test VPC and run preflight plus smoke write.
- Deploy a three-node Private stack with Bloom/GDS license secrets and run the Bloom/GDS assertions.

## Completion Criteria

- Complete: No documentation references unsupported TLS flags, unsupported CloudFormation TLS parameters, or Browser HTTPS on `7473`.
- Complete: No default tool path requires `AdvertisedDNS`, `CertificateArn`, `CertificateType`, `SelfSignedCertificate`, or `TrustCustomCAs`.
- Complete: Generated templates are up to date.
- Complete: `deploy.py --help` and the README deploy examples agree.
- Complete: The sample private app uses the published SSM contract fields.
- Pending AWS validation: Bloom/GDS license functionality remains intact and should be verified in an integration deploy.
