from __future__ import annotations

from dataclasses import dataclass


ENFORCED = "enforced"
ADVISORY = "advisory"
UNSUPPORTED = "unsupported"
SUPPORTED_RUNTIMES = {"claude-code", "opencode", "codex-cli"}
PRE_ACTION_ENFORCED_RUNTIMES = {"claude-code"}


@dataclass(frozen=True)
class CapabilityReport:
    runtime: str
    state_validation: str
    pre_action_project_write: str
    pre_action_dependency_write: str
    pre_action_destructive: str
    transcript_conformance: str

    def as_dict(self) -> dict[str, str]:
        return {
            "runtime": self.runtime,
            "state_validation": self.state_validation,
            "pre_action_project_write": self.pre_action_project_write,
            "pre_action_dependency_write": self.pre_action_dependency_write,
            "pre_action_destructive": self.pre_action_destructive,
            "transcript_conformance": self.transcript_conformance,
        }


def runtime_capabilities(runtime: str, *, pre_action_payload: bool = False, strict: bool = False) -> CapabilityReport:
    pre_action = ENFORCED if strict and pre_action_payload and runtime in PRE_ACTION_ENFORCED_RUNTIMES else ADVISORY
    if runtime not in SUPPORTED_RUNTIMES:
        pre_action = UNSUPPORTED
    return CapabilityReport(
        runtime=runtime,
        state_validation=ENFORCED if strict else ADVISORY,
        pre_action_project_write=pre_action,
        pre_action_dependency_write=pre_action,
        pre_action_destructive=pre_action,
        transcript_conformance=ENFORCED if strict else ADVISORY,
    )


def format_report(report: CapabilityReport) -> str:
    values = report.as_dict()
    return "\n".join(f"{key}: {value}" for key, value in values.items())
