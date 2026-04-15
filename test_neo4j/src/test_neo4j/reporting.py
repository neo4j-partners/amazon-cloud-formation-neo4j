"""Test result tracking, timing, and summary reporting."""

from __future__ import annotations

import contextlib
import dataclasses
import logging
import time
from collections.abc import Iterator

log = logging.getLogger(__name__)


@dataclasses.dataclass
class TestResult:
    name: str
    passed: bool
    message: str
    duration_seconds: float


class TestContext:
    """Yielded by TestReporter.test() to record pass/fail from within the block."""

    def __init__(self) -> None:
        self.passed: bool | None = None
        self.message: str = ""

    def pass_(self, message: str) -> None:
        self.passed = True
        self.message = message

    def fail(self, message: str) -> None:
        self.passed = False
        self.message = message


class TestReporter:
    def __init__(self) -> None:
        self._results: list[TestResult] = []
        self._suite_start: float = time.monotonic()
        self._test_number: int = 0

    @contextlib.contextmanager
    def test(self, name: str) -> Iterator[TestContext]:
        """Context manager that times a test and records the result."""
        self._test_number += 1
        num = self._test_number
        log.info("--- Test %d: %s ---", num, name)

        ctx = TestContext()
        start = time.monotonic()
        try:
            yield ctx
        except Exception as exc:
            # Always override to fail on exception, even if pass_() was called
            ctx.fail(f"Exception: {exc}")
        finally:
            duration = time.monotonic() - start
            if ctx.passed is None:
                ctx.fail("Test did not record a result")

            result = TestResult(
                name=name,
                passed=bool(ctx.passed),
                message=ctx.message,
                duration_seconds=duration,
            )
            self._results.append(result)

            tag = "PASS" if result.passed else "FAIL"
            log.info("  %s: %s  (%.1fs)\n", tag, result.message, duration)

    def summary(self, *, stack_name: str, endpoint: str) -> int:
        """Print a summary table and return the exit code (0=all pass, 1=failures)."""
        total_time = time.monotonic() - self._suite_start
        failures = sum(1 for r in self._results if not r.passed)

        lines = [
            "=============================================",
            "  Stack Test Results",
            "=============================================",
            "",
            f"  Stack:     {stack_name}",
            f"  Endpoint:  {endpoint}",
            "",
        ]

        for i, r in enumerate(self._results, 1):
            tag = "PASS" if r.passed else "FAIL"
            lines.append(f"  {i:>2}. {r.name:<35s} {tag}  ({r.duration_seconds:.1f}s)")

        lines.append("")
        if failures > 0:
            lines.append(f"  RESULT: {failures} of {len(self._results)} test(s) FAILED  (total: {total_time:.1f}s)")
        else:
            lines.append(f"  RESULT: All {len(self._results)} tests PASSED  (total: {total_time:.1f}s)")
        lines.append("")
        lines.append("=============================================")

        log.info("\n".join(lines))
        return 1 if failures else 0
