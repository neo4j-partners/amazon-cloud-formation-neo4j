# TLS Phase 1-7 Review Fixes

Review target: current implementation against `neo4j-ee/worklog/tls.md` phases 1-7.

Validation run during review:

- `python templates/build.py --verify` from `neo4j-ee/`: passes.
- `python -m py_compile deploy.py certificate.py` from `neo4j-ee/`: passes.
- `./deploy.py --help` from `neo4j-ee/`: shows the new TLS flags and no `--tls`.
- `python -m unittest discover -s tests` from `neo4j-ee/`: passes, 76 tests.
- `cfn-lint templates/neo4j-private.template.yaml templates/neo4j-public.template.yaml templates/neo4j-private-existing-vpc.template.yaml`: no errors, but exits non-zero with `W1030` warnings in the ExistingVpc template.

## Must Fix

1. Add teardown support for auto-imported ACM certificates.

   `deploy.py` now auto-imports a self-signed ACM certificate for the Private and ExistingVpc test path, records `CertificateArn` in `.deploy/<stack>.txt`, and clears the atexit cleanup marker after successful stack creation. That is correct for stack lifetime, but `neo4j-ee/teardown.sh` still only looks for the old `BoltTlsSecretArn` secret and never deletes the auto-imported ACM certificate.

   Fix by recording whether the cert was auto-imported, for example `AutoImportedCertificateArn`, and teaching `teardown.sh` to delete that ACM certificate after CloudFormation stack deletion. Do not delete user-supplied certs.

2. Fix `certificate.py` deploy instructions or implement the advertised auto-detection.

   `certificate.py` writes `.deploy/cert-<domain>.json` and prints commands such as `./deploy.py  # cert file is auto-detected`, but current `deploy.py` does not read those cert files. This will mislead operators into deploying with a fresh auto-imported self-signed cert instead of the cert they just requested.

   Either implement cert-file discovery in `deploy.py` with clear selection rules, or remove the auto-detected wording and always print explicit `--cert-arn ... --advertised-dns ...` commands.

3. Fix `certificate.py --self-signed` guidance around private DNS.

   The self-signed path prints a deploy command with `--create-private-dns` but does not include `--private-dns-zone` or `--private-dns-hosted-zone-id`. With the current template, `CreatePrivateDns=true` and an empty `PrivateDnsZoneName` attempts to create a hosted zone with an empty name. It also contradicts D6, which says the default self-signed test path should not require Route 53.

   Fix by omitting `--create-private-dns` from the default self-signed command. If showing a private-DNS example, include a real zone flag and label it as optional.

4. Add deploy-time validation for private DNS options.

   `deploy.py` accepts `--create-private-dns` without requiring either `--private-dns-zone` or `--private-dns-hosted-zone-id`. That should fail before uploading a template or creating a stack, because the template cannot create a useful hosted zone with an empty name.

   Also reject or warn on private-DNS flags in Public mode, since Public mode never creates the Route 53 private DNS resources.

5. Update downstream tooling that still keys TLS off `BoltTlsSecretArn`.

   Several tools still use the removed secret-output signal:

   - `neo4j-ee/sample-private-app/deploy-sample-private-app.py` checks `BoltTlsSecretArn` to decide whether to use `+ssc`.
   - `neo4j-ee/sample-private-app/README.md` still documents `deploy.py --tls` and `BoltTlsSecretArn`.
   - `test_neo4j/src/test_neo4j/config.py` checks `BoltTlsSecretArn`.
   - `test_neo4j/src/test_neo4j/_infra_impl.py` still expects `7474` and `7687`.

   Fix these to use the same contract as `neo4j_ee.outputs.resolve_bolt_scheme`: TLS is signalled by non-empty `AdvertisedDNS`, and operator/test clients use `+ssc`.

## Should Fix

6. Align SSM output descriptions with the operator scheme contract.

   `outputs-private.yaml` and `outputs-existing-vpc.yaml` still describe the Bolt tunnel as `neo4j+s://<AdvertisedDNS>:7687`, while the actual tunnel scripts print `neo4j+ssc://...` for TLS stacks. This can make the self-signed test path look broken, since `+s` requires trust and hostname verification while D5/D6 deliberately chose `+ssc` for operator tooling.

   Fix the SSM command descriptions to say `neo4j+ssc://<AdvertisedDNS>:7687` for operator tunnel use, and keep `neo4j+s://<AdvertisedDNS>:7687` documented separately for production clients with trusted DNS and certs.

7. Update stale docs and diagnostics for port 7473.

   `neo4j-ee/README.md` still shows `./deploy.py --tls`. `neo4j-ee/validate-private/README.md` still describes Browser tunneling on `7474` and `http://localhost:7474`. `neo4j-ee/validate-private/scripts/ssm_tunnel_test.py` still defaults to remote port `7474` and performs plain HTTP checks.

   Fix these so the documented operator path matches phase 6: Browser is HTTPS on `7473`, and Bolt is TLS on `7687`.

8. Decide whether Public mode should reject ignored TLS inputs.

   In Public mode, `--cert-arn` and `--advertised-dns` are ignored unless `--enable-public-tls` is set. That can create a surprising plain-TCP public stack even though the operator supplied cert material.

   Prefer failing fast when Public mode receives TLS inputs without `--enable-public-tls`, or at least print a loud warning before stack creation.

9. Add a dry-run or unit-testable parameter builder for `deploy.py`.

   Phase 7 asks for a dry-run or unit-level verification that builds the expected CloudFormation parameter set without calling AWS. The current code builds parameters inside `main()` after AWS calls and has no test seam.

   Extract TLS resolution and CloudFormation parameter construction into pure helpers. Cover at least: Private default self-signed path, Private with supplied cert, Public without TLS, Public with TLS, ExistingVpc with private DNS, and invalid private-DNS combinations.

10. Clean or document the current `cfn-lint` warnings.

   The rendered templates are build-identical, but `cfn-lint` exits with `W1030` warnings in `neo4j-private-existing-vpc.template.yaml` around optional `ExistingEndpointSgId`, `PrivateSubnet2Id`, and `PrivateSubnet3Id` references. The worklog says the local gate was fully clean, so either fix the parameter typing/conditions or record these as an accepted ExistingVpc baseline.

## Lower Priority Cleanup

11. Remove unused imports from `deploy.py`.

   After removing the old `cryptography` certificate generator and two-phase TLS update path, imports such as `datetime`, `json`, and `subprocess` appear unnecessary. Cleaning them up keeps the phase-7 removal complete and makes future review easier.

12. Clarify public vs private DNS wording in certificate and parameter text.

   Some descriptions call `AdvertisedDNS` a public DNS name even though Private and ExistingVpc use it as an internal or operator-mapped name. Use "advertised DNS name" unless the text is specifically about Public mode.
