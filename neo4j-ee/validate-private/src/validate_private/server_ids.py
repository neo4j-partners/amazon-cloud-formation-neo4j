"""Instance ↔ server-UUID mapping via the Neo4j server_id binary file."""

from __future__ import annotations

import concurrent.futures
import logging

from validate_private.runner import run_shell_on_instance

log = logging.getLogger(__name__)

_READ_SERVER_ID = (
    "python3.11 -c \""
    "import uuid; "
    "d=open('/var/lib/neo4j/data/server_id','rb').read(); "
    "print(str(uuid.UUID(bytes=d[1:])))"
    "\""
)


def read_server_uuid(ssm, instance_id: str) -> str | None:
    """Decode /var/lib/neo4j/data/server_id on instance_id. Returns UUID string or None."""
    ok, stdout, stderr = run_shell_on_instance(ssm, instance_id, _READ_SERVER_ID, timeout_s=30)
    if not ok:
        log.warning("  server_id read failed on %s: %s", instance_id, stderr)
        return None
    decoded = stdout.strip()
    return decoded if decoded else None


def build_uuid_to_instance_map(ssm, instance_ids: list[str]) -> dict[str, str]:
    """Return {server_uuid: instance_id} for all instances that respond."""
    result: dict[str, str] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(instance_ids) or 1) as exe:
        futs = {exe.submit(read_server_uuid, ssm, iid): iid for iid in instance_ids}
        for fut in concurrent.futures.as_completed(futs):
            iid = futs[fut]
            uuid_str = fut.result()
            if uuid_str:
                result[uuid_str] = iid
    return result
