from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import textwrap
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
PARTIALS = REPO_ROOT / "neo4j-ee" / "templates" / "src" / "partials"
BUILD_PY = REPO_ROOT / "neo4j-ee" / "templates" / "build.py"


class ShellPartialTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.tmp = Path(self.tmpdir.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.command_log = self.tmp / "commands.log"
        self.fail_log = self.tmp / "fail.log"

    def tearDown(self) -> None:
        self.tmpdir.cleanup()

    def write_stub(self, name: str, body: str) -> Path:
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + textwrap.dedent(body))
        path.chmod(0o755)
        return path

    def run_shell(
        self,
        script: str,
        *,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        run_env = os.environ.copy()
        run_env.update(
            {
                "PATH": f"{self.bin}{os.pathsep}{run_env['PATH']}",
                "TEST_TMP": str(self.tmp),
                "COMMAND_LOG": str(self.command_log),
                "FAIL_LOG": str(self.fail_log),
            }
        )
        if env:
            run_env.update(env)
        return subprocess.run(
            ["bash", "-c", textwrap.dedent(script)],
            cwd=REPO_ROOT,
            env=run_env,
            text=True,
            capture_output=True,
            check=False,
        )

    def fail_function(self) -> str:
        return """
        fail() {
          echo "$*" >> "$FAIL_LOG"
          exit 42
        }
        """

    def test_set_neo4j_conf_replaces_uncomments_appends_and_is_idempotent(self) -> None:
        conf = self.tmp / "neo4j.conf"
        conf.write_text("#alpha=old\nbeta=old\nserverXdefault_address=keep\n")

        result = self.run_shell(
            f"""
            set -euo pipefail
            export NEO4J_CONF="{conf}"
            source "{PARTIALS / 'set-neo4j-conf.sh'}"
            set_neo4j_conf alpha one
            set_neo4j_conf beta two
            set_neo4j_conf gamma three
            set_neo4j_conf alpha one
            set_neo4j_conf server.default_address 0.0.0.0
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            conf.read_text().splitlines(),
            [
                "alpha=one",
                "beta=two",
                "serverXdefault_address=keep",
                "gamma=three",
                "server.default_address=0.0.0.0",
            ],
        )

    def test_fetch_and_install_license_writes_secret_with_restricted_mode(self) -> None:
        self.write_stub(
            "aws",
            """
            printf 'license-body'
            """,
        )
        self.write_stub(
            "chown",
            """
            echo "chown $*" >> "$COMMAND_LOG"
            """,
        )
        dest = self.tmp / "licenses" / "neo4j-gds.license"

        result = self.run_shell(
            f"""
            set -euo pipefail
            source "{PARTIALS / 'install-license.sh'}"
            {self.fail_function()}
            region=us-east-1
            fetch_and_install_license arn:test "{dest}" GDS
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(dest.read_text(), "license-body")
        self.assertEqual(stat.S_IMODE(dest.stat().st_mode), 0o600)
        self.assertIn("chown neo4j:neo4j", self.command_log.read_text())

    def test_fetch_and_install_license_fails_on_empty_none_and_aws_errors(self) -> None:
        for mode, body, expected in [
            ("empty", "exit 0", "returned an empty SecretString payload"),
            ("none", "echo None", "returned an empty SecretString payload"),
            ("fail", "exit 99", "Failed to fetch Bloom license secret"),
        ]:
            with self.subTest(mode=mode):
                self.write_stub("aws", body)
                self.write_stub("chown", "exit 0\n")
                self.fail_log.write_text("")
                dest = self.tmp / f"{mode}.license"

                result = self.run_shell(
                    f"""
                    set -euo pipefail
                    source "{PARTIALS / 'install-license.sh'}"
                    {self.fail_function()}
                    region=us-east-1
                    fetch_and_install_license arn:test "{dest}" Bloom
                    """
                )

                self.assertEqual(result.returncode, 42, result.stderr)
                self.assertIn(expected, self.fail_log.read_text())

    def test_extension_config_gates_bloom_and_gds_license_settings(self) -> None:
        conf = self.tmp / "neo4j.conf"
        conf.write_text("dbms.jvm.additional=-agentlib:jdwp=test\nkeep=true\n")
        set_log = self.tmp / "set-conf.log"

        result = self.run_shell(
            f"""
            set -euo pipefail
            export NEO4J_CONF="{conf}"
            export NEO4J_HOME="{self.tmp / 'neo4j'}"
            source "{PARTIALS / 'configure-neo4j.sh'}"
            set_neo4j_conf() {{
              echo "$1=$2" >> "{set_log}"
            }}
            installBloom=true
            bloomLicenseSecretArn=arn:bloom
            installGDS=true
            gdsLicenseSecretArn=arn:gds
            extension_config
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = set_log.read_text()
        self.assertIn("server.unmanaged_extension_classes=com.neo4j.bloom.server=/bloom,semantics.extension=/rdf", calls)
        self.assertIn(f"dbms.bloom.license_file={self.tmp / 'neo4j' / 'licenses' / 'neo4j-bloom.license'}", calls)
        self.assertIn(f"gds.enterprise.license_file={self.tmp / 'neo4j' / 'licenses' / 'neo4j-gds.license'}", calls)
        self.assertEqual(conf.read_text(), "keep=true\n")

    def test_extension_config_omits_license_files_when_license_arns_are_empty(self) -> None:
        conf = self.tmp / "neo4j.conf"
        conf.write_text("keep=true\n")
        set_log = self.tmp / "set-conf.log"

        result = self.run_shell(
            f"""
            set -euo pipefail
            export NEO4J_CONF="{conf}"
            source "{PARTIALS / 'configure-neo4j.sh'}"
            set_neo4j_conf() {{
              echo "$1=$2" >> "{set_log}"
            }}
            installBloom=true
            bloomLicenseSecretArn=
            installGDS=true
            gdsLicenseSecretArn=
            extension_config
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = set_log.read_text()
        self.assertIn("server.unmanaged_extension_classes=", calls)
        self.assertNotIn("dbms.bloom.license_file", calls)
        self.assertNotIn("gds.enterprise.license_file", calls)

    def test_build_neo4j_conf_file_single_node_sets_expected_config(self) -> None:
        self.write_stub("hostname", "echo '10.0.0.10 172.31.0.10'\n")
        self.write_stub("neo4j-admin", "echo 'server.memory.heap.max_size=4g'\n")
        conf = self.tmp / "neo4j.conf"
        conf.write_text("")
        set_log = self.tmp / "set-conf.log"

        result = self.run_shell(
            f"""
            set -euo pipefail
            export NEO4J_CONF="{conf}"
            source "{PARTIALS / 'configure-neo4j.sh'}"
            set_neo4j_conf() {{
              echo "$1=$2" >> "{set_log}"
            }}
            loadBalancerDNSName=lb.example.com
            boltAdvertisedDNS=bolt.example.com
            nodeCount=1
            boltCertArn=
            build_neo4j_conf_file
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = set_log.read_text()
        self.assertIn("server.default_advertised_address=lb.example.com", calls)
        self.assertIn("server.bolt.advertised_address=bolt.example.com:7687", calls)
        self.assertIn("server.metrics.enabled=true", calls)
        self.assertIn("dbms.routing.default_router=SERVER", calls)
        self.assertIn("server.memory.heap.max_size=4g", conf.read_text())

    def test_build_neo4j_conf_file_cluster_discovers_peer_endpoints(self) -> None:
        self.write_stub("hostname", "echo '172.31.0.10'\n")
        self.write_stub("neo4j-admin", "echo 'memory=recommended'\n")
        self.write_stub("sleep", "exit 0\n")
        self.write_stub(
            "aws",
            """
            args="$*"
            if [[ "$args" == *"AutoScalingGroups[?Tags"* ]]; then
              echo "asg-a"
            elif [[ "$args" == *"AutoScalingGroups[].Instances[].InstanceId"* ]]; then
              echo "i-1 i-2 i-3"
            elif [[ "$args" == *"Reservations[].Instances[].PrivateIpAddress"* ]]; then
              printf '10.0.0.1\\n10.0.0.2\\n10.0.0.3\\n'
            fi
            """,
        )
        conf = self.tmp / "neo4j.conf"
        conf.write_text("")
        set_log = self.tmp / "set-conf.log"

        result = self.run_shell(
            f"""
            set -euo pipefail
            export NEO4J_CONF="{conf}"
            source "{PARTIALS / 'configure-neo4j.sh'}"
            {self.fail_function()}
            set_neo4j_conf() {{
              echo "$1=$2" >> "{set_log}"
            }}
            region=us-east-1
            _stack_id=stack-arn
            loadBalancerDNSName=lb.example.com
            boltAdvertisedDNS=
            nodeCount=3
            boltCertArn=
            build_neo4j_conf_file
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = set_log.read_text()
        self.assertIn("server.cluster.advertised_address=172.31.0.10:6000", calls)
        self.assertIn("initial.dbms.default_secondaries_count=0", calls)
        self.assertIn("dbms.cluster.discovery.resolver_type=LIST", calls)
        self.assertIn("dbms.cluster.endpoints=10.0.0.1:6000,10.0.0.2:6000,10.0.0.3:6000", calls)

    def test_build_neo4j_conf_file_fails_when_peer_discovery_finds_no_members(self) -> None:
        self.write_stub("hostname", "echo '172.31.0.10'\n")
        self.write_stub("neo4j-admin", "echo 'memory=recommended'\n")
        self.write_stub("sleep", "exit 0\n")
        self.write_stub("aws", "exit 0\n")
        conf = self.tmp / "neo4j.conf"
        conf.write_text("")

        result = self.run_shell(
            f"""
            set -euo pipefail
            export NEO4J_CONF="{conf}"
            source "{PARTIALS / 'configure-neo4j.sh'}"
            {self.fail_function()}
            set_neo4j_conf() {{ :; }}
            region=us-east-1
            _stack_id=stack-arn
            loadBalancerDNSName=lb.example.com
            boltAdvertisedDNS=
            nodeCount=3
            boltCertArn=
            build_neo4j_conf_file
            """
        )

        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("Peer discovery failed after 5 minutes.", self.fail_log.read_text())

    def test_build_neo4j_conf_file_installs_bolt_tls_secret(self) -> None:
        self.write_stub("hostname", "echo '172.31.0.10'\n")
        self.write_stub("neo4j-admin", "echo 'memory=recommended'\n")
        self.write_stub("aws", "echo '{\"certificate\":\"CERT\",\"private_key\":\"KEY\"}'\n")
        self.write_stub("chown", "echo \"chown $*\" >> \"$COMMAND_LOG\"\n")
        self.write_stub(
            "jq",
            """
            expr="${*: -1}"
            if [[ "$*" == *"has("* ]]; then
              exit 0
            elif [[ "$expr" == ".private_key" ]]; then
              echo "KEY"
            elif [[ "$expr" == ".certificate" ]]; then
              echo "CERT"
            fi
            """,
        )
        conf = self.tmp / "neo4j.conf"
        conf.write_text("")
        set_log = self.tmp / "set-conf.log"
        cert_dir = self.tmp / "certificates" / "bolt"

        result = self.run_shell(
            f"""
            set -euo pipefail
            export NEO4J_CONF="{conf}"
            export NEO4J_CERT_DIR="{cert_dir}"
            source "{PARTIALS / 'configure-neo4j.sh'}"
            {self.fail_function()}
            set_neo4j_conf() {{
              echo "$1=$2" >> "{set_log}"
            }}
            region=us-east-1
            loadBalancerDNSName=lb.example.com
            boltAdvertisedDNS=
            nodeCount=1
            boltCertArn=arn:bolt
            build_neo4j_conf_file
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((cert_dir / "private.key").read_text(), "KEY\n")
        self.assertEqual((cert_dir / "public.crt").read_text(), "CERT\n")
        calls = set_log.read_text()
        self.assertIn("dbms.ssl.policy.bolt.enabled=true", calls)
        self.assertIn(f"dbms.ssl.policy.bolt.base_directory={cert_dir}", calls)
        self.assertIn("server.bolt.tls_level=REQUIRED", calls)

    def test_build_neo4j_conf_file_rejects_invalid_bolt_tls_secret(self) -> None:
        self.write_stub("hostname", "echo '172.31.0.10'\n")
        self.write_stub("neo4j-admin", "echo 'memory=recommended'\n")
        self.write_stub("aws", "echo '{\"certificate\":\"CERT\"}'\n")
        self.write_stub("jq", "exit 1\n")
        conf = self.tmp / "neo4j.conf"
        conf.write_text("")

        result = self.run_shell(
            f"""
            set -euo pipefail
            export NEO4J_CONF="{conf}"
            export NEO4J_CERT_DIR="{self.tmp / 'certificates' / 'bolt'}"
            source "{PARTIALS / 'configure-neo4j.sh'}"
            {self.fail_function()}
            set_neo4j_conf() {{ :; }}
            region=us-east-1
            loadBalancerDNSName=lb.example.com
            boltAdvertisedDNS=
            nodeCount=1
            boltCertArn=arn:bolt
            build_neo4j_conf_file
            """
        )

        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("must be JSON with fields", self.fail_log.read_text())

    def test_install_plugins_success_and_missing_jar_failures(self) -> None:
        self.write_stub("chown", "echo \"chown $*\" >> \"$COMMAND_LOG\"\n")
        neo4j_home = self.tmp / "neo4j"
        for subdir in ["labs", "products", "plugins"]:
            (neo4j_home / subdir).mkdir(parents=True, exist_ok=True)
        (neo4j_home / "labs" / "apoc-5-core.jar").write_text("apoc")
        (neo4j_home / "products" / "bloom-plugin-1.jar").write_text("bloom")
        (neo4j_home / "products" / "neo4j-graph-data-science-1.jar").write_text("gds")

        result = self.run_shell(
            f"""
            set -euo pipefail
            export NEO4J_HOME="{neo4j_home}"
            source "{PARTIALS / 'install-plugins.sh'}"
            {self.fail_function()}
            install_apoc
            install_plugin Bloom "bloom-plugin-*.jar"
            install_plugin GDS "neo4j-graph-data-science-*.jar"
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((neo4j_home / "plugins" / "apoc-5-core.jar").read_text(), "apoc")
        self.assertEqual((neo4j_home / "plugins" / "bloom-plugin-1.jar").read_text(), "bloom")
        self.assertEqual((neo4j_home / "plugins" / "neo4j-graph-data-science-1.jar").read_text(), "gds")

        (neo4j_home / "labs" / "apoc-5-core.jar").unlink()
        self.fail_log.write_text("")
        result = self.run_shell(
            f"""
            set -euo pipefail
            export NEO4J_HOME="{neo4j_home}"
            source "{PARTIALS / 'install-plugins.sh'}"
            {self.fail_function()}
            install_apoc
            """
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("APOC core JAR not found", self.fail_log.read_text())

        (neo4j_home / "products" / "neo4j-graph-data-science-1.jar").unlink()
        self.fail_log.write_text("")
        result = self.run_shell(
            f"""
            set -euo pipefail
            export NEO4J_HOME="{neo4j_home}"
            source "{PARTIALS / 'install-plugins.sh'}"
            {self.fail_function()}
            install_plugin GDS "neo4j-graph-data-science-*.jar"
            """
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("GDS JAR not found", self.fail_log.read_text())

    def test_install_neo4j_commands_and_first_boot_password(self) -> None:
        self.write_stub("yum", "echo \"yum $* accept=${NEO4J_ACCEPT_LICENSE_AGREEMENT:-}\" >> \"$COMMAND_LOG\"\n")
        self.write_stub("systemctl", "echo \"systemctl $*\" >> \"$COMMAND_LOG\"\n")
        self.write_stub("service", "echo \"service $*\" >> \"$COMMAND_LOG\"\n")
        self.write_stub("neo4j-admin", "echo \"neo4j-admin $*\" >> \"$COMMAND_LOG\"\n")

        result = self.run_shell(
            f"""
            set -euo pipefail
            source "{PARTIALS / 'install-neo4j.sh'}"
            password=secret
            IS_FIRST_BOOT=true
            install_neo4j_from_yum
            start_neo4j
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.command_log.read_text()
        self.assertIn("yum -y install neo4j-enterprise accept=yes", log)
        self.assertIn("systemctl enable neo4j", log)
        self.assertIn("service neo4j start", log)
        self.assertIn("neo4j-admin dbms set-initial-password secret", log)

        self.command_log.write_text("")
        result = self.run_shell(
            f"""
            set -euo pipefail
            source "{PARTIALS / 'install-neo4j.sh'}"
            password=secret
            IS_FIRST_BOOT=false
            start_neo4j
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("set-initial-password", self.command_log.read_text())

    def test_cloudwatch_config_is_valid_json_and_invokes_agent_control(self) -> None:
        self.write_stub("amazon-cloudwatch-agent-ctl", "echo \"cwctl $*\" >> \"$COMMAND_LOG\"\n")
        config = self.tmp / "amazon-cloudwatch-agent.json"

        result = self.run_shell(
            f"""
            set -euo pipefail
            export CW_AGENT_CONFIG="{config}"
            export CW_AGENT_CTL=amazon-cloudwatch-agent-ctl
            source "{PARTIALS / 'configure-cloudwatch.sh'}"
            stackName=demo
            install_cloudwatch_agent
            """
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(config.read_text())
        collect_list = payload["logs"]["logs_collected"]["files"]["collect_list"]
        paths = {item["file_path"] for item in collect_list}
        self.assertEqual(
            paths,
            {
                "/var/log/neo4j/security.log",
                "/var/log/neo4j/debug.log",
                "/var/log/cloud-init-output.log",
            },
        )
        self.assertTrue(all(item["log_group_name"] == "/neo4j/demo/application" for item in collect_list))
        self.assertIn(f"file:{config}", self.command_log.read_text())

    def write_attach_stubs(self) -> None:
        self.write_stub(
            "aws",
            """
            args="$*"
            echo "aws $args" >> "$COMMAND_LOG"
            if [[ "$args" == *"attach-volume"* ]]; then
              count_file="$TEST_TMP/attach-count"
              count=0
              [[ -f "$count_file" ]] && count=$(cat "$count_file")
              count=$((count + 1))
              echo "$count" > "$count_file"
              if (( count <= ${AWS_ATTACH_FAILS:-0} )); then
                exit 1
              fi
              exit 0
            fi
            if [[ "$args" == *"Volumes[*].VolumeId"* ]]; then
              printf '%s\\n' "${AWS_VOLUMES-vol-123456}"
            elif [[ "$args" == *"Volumes[0].State"* ]]; then
              echo "${AWS_VOLUME_STATE:-available}"
            elif [[ "$args" == *"Attachments[0].State"* ]]; then
              echo "${AWS_ATTACHMENT_STATE:-attached}"
            fi
            """,
        )
        self.write_stub("sleep", "echo \"sleep $*\" >> \"$COMMAND_LOG\"\n")
        self.write_stub("udevadm", "echo \"udevadm $*\" >> \"$COMMAND_LOG\"\n")
        self.write_stub("lsblk", "echo \"${LSBLK_SERIAL:-vol123456}\"\n")
        self.write_stub(
            "blkid",
            """
            if [[ "${1:-}" == "-s" ]]; then
              printf '%s\\n' "${BLKID_UUID-uuid-1234}"
              exit 0
            fi
            if [[ "${BLKID_HAS_FS:-true}" == "true" ]]; then
              exit 0
            fi
            exit 1
            """,
        )
        self.write_stub("mkfs.xfs", "echo \"mkfs.xfs $*\" >> \"$COMMAND_LOG\"\n")
        self.write_stub("mount", "echo \"mount $*\" >> \"$COMMAND_LOG\"\n")
        self.write_stub("chown", "echo \"chown $*\" >> \"$COMMAND_LOG\"\n")

    def run_attach(self, *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        dev = self.tmp / "nvme1n1"
        dev.touch()
        data_dir = self.tmp / "data"
        fstab = self.tmp / "fstab"
        run_env = {
            "NEO4J_DATA_DIR": str(data_dir),
            "FSTAB_PATH": str(fstab),
            "NVME_DEVICE_GLOB": str(self.tmp / "nvme?n1"),
            "ALLOW_REGULAR_NVME_DEVICES": "true",
            "AWS_VOLUMES": "vol-123456",
            "LSBLK_SERIAL": "vol123456",
            "BLKID_UUID": "uuid-1234",
        }
        if env:
            run_env.update(env)
        return self.run_shell(
            f"""
            set -euo pipefail
            source "{PARTIALS / 'attach-data-volume.sh'}"
            {self.fail_function()}
            region=us-east-1
            _stack_id=stack-arn
            _az=us-east-1a
            _instance_id=i-123
            IS_FIRST_BOOT=false
            attach_and_mount_data_volume
            echo "IS_FIRST_BOOT=$IS_FIRST_BOOT" > "{self.tmp / 'first-boot-state'}"
            """,
            env=run_env,
        )

    def test_attach_data_volume_validates_volume_count(self) -> None:
        self.write_attach_stubs()

        result = self.run_attach(env={"AWS_VOLUMES": ""})
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("Expected 1 data volume", self.fail_log.read_text())

        self.fail_log.write_text("")
        result = self.run_attach(env={"AWS_VOLUMES": "vol-1 vol-2"})
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("Expected 1 data volume", self.fail_log.read_text())

    def test_attach_data_volume_fails_when_volume_never_available(self) -> None:
        self.write_attach_stubs()

        result = self.run_attach(env={"AWS_VOLUME_STATE": "in-use"})

        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("not available after 10m", self.fail_log.read_text())

    def test_attach_data_volume_retries_attach_and_mounts_existing_filesystem(self) -> None:
        self.write_attach_stubs()

        result = self.run_attach(env={"AWS_ATTACH_FAILS": "2", "BLKID_HAS_FS": "true"})

        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.command_log.read_text()
        self.assertEqual((self.tmp / "attach-count").read_text().strip(), "3")
        self.assertIn(f"mount {self.tmp / 'data'}", log)
        self.assertNotIn("mkfs.xfs", log)
        self.assertIn(f"UUID=uuid-1234  {self.tmp / 'data'}  xfs", (self.tmp / "fstab").read_text())
        self.assertEqual((self.tmp / "first-boot-state").read_text().strip(), "IS_FIRST_BOOT=false")

    def test_attach_data_volume_fails_after_attach_retry_exhaustion(self) -> None:
        self.write_attach_stubs()

        result = self.run_attach(env={"AWS_ATTACH_FAILS": "3"})

        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("attach-volume failed", self.fail_log.read_text())

    def test_attach_data_volume_fails_when_attachment_state_never_attached(self) -> None:
        self.write_attach_stubs()

        result = self.run_attach(env={"AWS_ATTACHMENT_STATE": "attaching"})

        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("not attached in 2m", self.fail_log.read_text())

    def test_attach_data_volume_formats_first_boot_and_chowns_data_dir(self) -> None:
        self.write_attach_stubs()

        result = self.run_attach(env={"BLKID_HAS_FS": "false"})

        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.command_log.read_text()
        self.assertIn(f"mkfs.xfs {self.tmp / 'nvme1n1'}", log)
        self.assertIn(f"chown neo4j:neo4j {self.tmp / 'data'}", log)
        self.assertEqual((self.tmp / "first-boot-state").read_text().strip(), "IS_FIRST_BOOT=true")

    def test_attach_data_volume_fails_when_nvme_device_cannot_be_resolved(self) -> None:
        self.write_attach_stubs()

        result = self.run_attach(env={"LSBLK_SERIAL": "different-serial"})

        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("Could not resolve NVMe device", self.fail_log.read_text())

    def test_attach_data_volume_fails_when_uuid_is_missing(self) -> None:
        self.write_attach_stubs()

        result = self.run_attach(env={"BLKID_UUID": ""})

        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("No UUID", self.fail_log.read_text())


class RenderedTemplateContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        spec = importlib.util.spec_from_file_location("ee_template_build", BUILD_PY)
        assert spec is not None
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        cls.templates = {
            "private": module._assemble_private(),
            "public": module._assemble_public(),
            "existing_vpc": module._assemble_existing_vpc(),
        }

    def test_all_templates_include_shared_userdata_contracts(self) -> None:
        for name, template in self.templates.items():
            with self.subTest(template=name):
                self.assertIn("fetch_and_install_license", template)
                self.assertIn("attach_and_mount_data_volume", template)
                self.assertIn("build_neo4j_conf_file", template)
                self.assertIn("start_neo4j", template)
                self.assertLess(template.index("start_neo4j"), template.index("cfn-signal --success true"))
                self.assertIn('secret-id "neo4j/${stackName}/password"', template)
                self.assertNotIn('password="', template)

    def test_templates_preserve_plugin_license_rules(self) -> None:
        for name, template in self.templates.items():
            with self.subTest(template=name):
                self.assertIn("BloomLicenseRequiredWhenInstalled", template)
                self.assertIn("GdsLicenseRequiredWhenInstalled", template)
                self.assertIn("BloomLicenseSecretArn", template)
                self.assertIn("GdsLicenseSecretArn", template)

    def test_license_iam_grants_are_conditional_and_not_wildcarded(self) -> None:
        for name, template in self.templates.items():
            with self.subTest(template=name):
                self.assertIn("BloomEnabledAndLicensed", template)
                self.assertIn("GdsEnabledAndLicensed", template)
                self.assertIn("secretsmanager:GetSecretValue", template)
                self.assertIn("AWS::NoValue", template)
                self.assertNotIn("secret:*", template)

    def test_ebs_and_asg_creation_contracts_are_preserved(self) -> None:
        for name, template in self.templates.items():
            with self.subTest(template=name):
                self.assertIn("DeletionPolicy: Retain", template)
                self.assertIn("CreationPolicy:", template)
                self.assertIn("ResourceSignal:", template)


if __name__ == "__main__":
    unittest.main()
