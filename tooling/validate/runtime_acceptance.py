#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MCP_SENTINEL = "ACCEPTANCE_MCP_OK"
MCP_TOOL_CALL_MARKER = "ACCEPTANCE_MCP_TOOL_CALLED"


@dataclass
class ProbeResult:
    name: str
    status: str
    detail: str

    @property
    def ok(self) -> bool:
        return self.status == "ready"


@dataclass
class RuntimeProbe:
    runtime: str
    expected_kernel_path: str
    home: Path
    cli_path: str

    def env(self, extra_path: str | None = None) -> dict[str, str]:
        env = dict(os.environ)
        env["HOME"] = str(self.home)
        if extra_path:
            env["PATH"] = f"{extra_path}:{env.get('PATH', '')}"
        return env

    def run(self, prompt: str, extra_path: str | None = None, cwd: Path | None = None) -> tuple[int, str, str]:
        raise NotImplementedError


class ClaudeProbe(RuntimeProbe):
    def run(self, prompt: str, extra_path: str | None = None, cwd: Path | None = None) -> tuple[int, str, str]:
        if cwd is None:
            raise ValueError("ClaudeProbe.run requires a working directory")
        command = [
            self.cli_path,
            "-p",
            "--no-session-persistence",
            "--output-format",
            "text",
            prompt,
        ]
        completed = subprocess.run(
            command,
            cwd=cwd,
            env=self.env(extra_path),
            capture_output=True,
            text=True,
        )
        return completed.returncode, completed.stdout, completed.stderr


class CodexProbe(RuntimeProbe):
    def run(self, prompt: str, extra_path: str | None = None, cwd: Path | None = None) -> tuple[int, str, str]:
        if cwd is None:
            raise ValueError("CodexProbe.run requires a working directory")
        with tempfile.NamedTemporaryFile(prefix="b-agentic-codex-last-message-", delete=False) as handle:
            output_path = Path(handle.name)
        run_cwd = cwd
        command = [
            self.cli_path,
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "-C",
            str(run_cwd),
            "-o",
            str(output_path),
            prompt,
        ]
        completed = subprocess.run(
            command,
            cwd=run_cwd,
            env=self.env(extra_path),
            capture_output=True,
            text=True,
        )
        stdout = output_path.read_text() if output_path.exists() else completed.stdout
        output_path.unlink(missing_ok=True)
        return completed.returncode, stdout, completed.stderr


class OpenCodeProbe(RuntimeProbe):
    def run(self, prompt: str, extra_path: str | None = None, cwd: Path | None = None) -> tuple[int, str, str]:
        if cwd is None:
            raise ValueError("OpenCodeProbe.run requires a working directory")
        run_cwd = cwd
        command = [
            self.cli_path,
            "run",
            "--dir",
            str(run_cwd),
            prompt,
        ]
        completed = subprocess.run(
            command,
            cwd=run_cwd,
            env=self.env(extra_path),
            capture_output=True,
            text=True,
        )
        return completed.returncode, completed.stdout, completed.stderr


class PiProbe(RuntimeProbe):
    def run(self, prompt: str, extra_path: str | None = None, cwd: Path | None = None) -> tuple[int, str, str]:
        if cwd is None:
            raise ValueError("PiProbe.run requires a working directory")
        # Print mode is noninteractive and has no UI confirmation.
        command = [
            self.cli_path,
            "-p",
            "--no-session",
            prompt,
        ]
        completed = subprocess.run(
            command,
            cwd=cwd,
            env=self.env(extra_path),
            capture_output=True,
            text=True,
        )
        return completed.returncode, completed.stdout, completed.stderr


def load_runtime(runtime_name: str) -> dict:
    data = json.loads((ROOT / "runtimes" / "registry.yaml").read_text())
    for runtime in data.get("runtimes", []):
        if isinstance(runtime, dict) and runtime.get("name") == runtime_name:
            return runtime
    raise SystemExit(f"unsupported runtime: {runtime_name}")


def expected_kernel_path(runtime: dict) -> str:
    metadata_root = runtime["metadata_root"]
    return f"{metadata_root}/references/contract/"


def build_probe(runtime_name: str, home: Path) -> RuntimeProbe:
    runtime = load_runtime(runtime_name)
    cli_path = shutil.which(runtime_name.split("-")[0] if runtime_name != "codex" else "codex")
    if runtime_name == "claude-code":
        cli_path = shutil.which("claude")
    elif runtime_name == "opencode":
        cli_path = shutil.which("opencode")
    elif runtime_name == "codex":
        cli_path = shutil.which("codex")
    elif runtime_name == "pi":
        cli_path = shutil.which("pi")

    if cli_path is None:
        raise SystemExit(f"runtime CLI not found on PATH for {runtime_name}")

    common = {
        "runtime": runtime_name,
        "expected_kernel_path": expected_kernel_path(runtime),
        "home": home,
        "cli_path": cli_path,
    }
    if runtime_name == "claude-code":
        return ClaudeProbe(**common)
    if runtime_name == "codex":
        return CodexProbe(**common)
    if runtime_name == "opencode":
        return OpenCodeProbe(**common)
    if runtime_name == "pi":
        return PiProbe(**common)
    raise SystemExit(f"unsupported runtime: {runtime_name}")


def summarize_output(stdout: str, stderr: str) -> str:
    merged = "\n".join(part.strip() for part in (stdout, stderr) if part.strip()).strip()
    if not merged:
        return "no output"
    return merged[:240].replace("\n", " ")


def merged_output(stdout: str, stderr: str) -> str:
    return "\n".join(part for part in (stdout, stderr) if part).strip()


def log_contains_marker(path: Path, marker: str) -> bool:
    if not path.exists():
        return False
    return marker in path.read_text()


def has_gate_signal(stdout: str, stderr: str) -> bool:
    output = merged_output(stdout, stderr).lower()
    patterns = (
        r"\bapproval\b",
        r"\bapprove\b",
        r"\bapproved\b",
        r"\bdenied\b",
        r"\bdeny\b",
        r"\bpermission\b",
        r"\bblocked\b",
        r"\bnot allowed\b",
        r"\brequires approval\b",
        r"\bconfirmation\b",
        r"\bconfirm\b",
        r"\brejected\b",
    )
    return any(re.search(pattern, output) for pattern in patterns)


def make_temp_repo(label: str) -> Path:
    repo = Path(tempfile.mkdtemp(prefix=f"b-agentic-{label}-"))
    subprocess.run(["git", "init", "-q", str(repo)], check=True, cwd=repo)
    subprocess.run(["git", "config", "user.name", "b-agentic acceptance"], check=True, cwd=repo)
    subprocess.run(["git", "config", "user.email", "acceptance@example.com"], check=True, cwd=repo)
    return repo


def commit_file(repo: Path, relative_path: str, content: str, message: str) -> None:
    path = repo / relative_path
    path.write_text(content)
    subprocess.run(["git", "add", relative_path], check=True, cwd=repo)
    subprocess.run(["git", "commit", "-qm", message], check=True, cwd=repo)


def current_head(repo: Path) -> str:
    return subprocess.run(["git", "rev-parse", "HEAD"], check=True, cwd=repo, capture_output=True, text=True).stdout.strip()


def git_status(repo: Path) -> str:
    return subprocess.run(["git", "status", "--short"], check=True, cwd=repo, capture_output=True, text=True).stdout.strip()


def probe_kernel_loaded(probe: RuntimeProbe) -> ProbeResult:
    repo = make_temp_repo("runtime-kernel")
    try:
        prompt = "Reply with only the exact directory path mentioned after 'Detailed contract refs live under' in your active runtime kernel."
        rc, stdout, stderr = probe.run(prompt, cwd=repo)
        if rc != 0:
            return ProbeResult("kernel", "blocked", summarize_output(stdout, stderr))
        if probe.expected_kernel_path in stdout:
            return ProbeResult("kernel", "ready", probe.expected_kernel_path)
        return ProbeResult("kernel", "blocked", summarize_output(stdout, stderr))
    finally:
        shutil.rmtree(repo, ignore_errors=True)


def probe_skill_routing(probe: RuntimeProbe) -> ProbeResult:
    repo = make_temp_repo("runtime-skill")
    try:
        prompt = "Write a commit message, PR title, and PR description for the staged changes."
        rc, stdout, stderr = probe.run(prompt, cwd=repo)
        if rc != 0:
            return ProbeResult("skill", "blocked", summarize_output(stdout, stderr))
        expected = "BLOCKED: no changes to summarize"
        if expected in stdout:
            return ProbeResult("skill", "ready", expected)
        return ProbeResult("skill", "blocked", summarize_output(stdout, stderr))
    finally:
        shutil.rmtree(repo, ignore_errors=True)


def write_mock_serena(bin_dir: Path) -> None:
    server = textwrap.dedent(
        f"""\
        #!/usr/bin/env python3
        import json
        import os
        import sys

        log_path = os.environ.get("B_AGENTIC_ACCEPTANCE_MCP_LOG")

        def read_message():
            headers = {{}}
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return None
                if line in (b"\r\n", b"\n"):
                    break
                key, value = line.decode("utf-8").split(":", 1)
                headers[key.lower()] = value.strip()
            length = int(headers.get("content-length", "0"))
            if length <= 0:
                return None
            body = sys.stdin.buffer.read(length)
            return json.loads(body.decode("utf-8"))

        def send(message):
            payload = json.dumps(message).encode("utf-8")
            sys.stdout.buffer.write(f"Content-Length: {{len(payload)}}\\r\\n\\r\\n".encode("utf-8"))
            sys.stdout.buffer.write(payload)
            sys.stdout.buffer.flush()

        while True:
            message = read_message()
            if message is None:
                break
            method = message.get("method")
            if method == "initialize":
                send({{"jsonrpc": "2.0", "id": message.get("id"), "result": {{"protocolVersion": "2024-11-05", "serverInfo": {{"name": "b-agentic-serena-mock", "version": "0.1.0"}}, "capabilities": {{"tools": {{}}}}}}}})
            elif method == "tools/list":
                send({{"jsonrpc": "2.0", "id": message.get("id"), "result": {{"tools": [{{"name": "acceptance_probe", "description": "Returns the runtime acceptance sentinel.", "inputSchema": {{"type": "object", "properties": {{}}, "additionalProperties": False}}}}]}}}})
            elif method == "tools/call":
                name = (((message.get("params") or {{}}).get("name")) or "")
                if name == "acceptance_probe":
                    if log_path:
                        with open(log_path, "a", encoding="utf-8") as handle:
                            handle.write("{MCP_TOOL_CALL_MARKER}\\n")
                    send({{"jsonrpc": "2.0", "id": message.get("id"), "result": {{"content": [{{"type": "text", "text": "{MCP_SENTINEL}"}}]}}}})
                else:
                    send({{"jsonrpc": "2.0", "id": message.get("id"), "error": {{"code": -32601, "message": "unknown tool"}}}})
            elif method == "ping":
                send({{"jsonrpc": "2.0", "id": message.get("id"), "result": {{}}}})
            elif "id" in message:
                send({{"jsonrpc": "2.0", "id": message.get("id"), "result": {{}}}})
        """
    )
    path = bin_dir / "serena"
    path.write_text(server)
    path.chmod(0o755)


def probe_mcp_launch(probe: RuntimeProbe) -> ProbeResult:
    repo = make_temp_repo("runtime-mcp")
    bin_dir = Path(tempfile.mkdtemp(prefix="b-agentic-acceptance-bin-"))
    log_path = bin_dir / "serena.log"
    write_mock_serena(bin_dir)
    env_path = str(bin_dir)
    try:
        prompt = (
            "Use the Serena MCP tool named acceptance_probe and reply with only the exact tool text. "
            f"The expected tool text is {MCP_SENTINEL}."
        )
        extra_env = probe.env(env_path)
        extra_env["B_AGENTIC_ACCEPTANCE_MCP_LOG"] = str(log_path)
        if isinstance(probe, ClaudeProbe):
            command = [probe.cli_path, "-p", "--no-session-persistence", "--output-format", "text", prompt]
        elif isinstance(probe, PiProbe):
            command = [probe.cli_path, "-p", "--no-session", prompt]
        elif isinstance(probe, CodexProbe):
            with tempfile.NamedTemporaryFile(prefix="b-agentic-codex-last-message-", delete=False) as handle:
                output_path = Path(handle.name)
            command = [probe.cli_path, "exec", "--skip-git-repo-check", "--ephemeral", "-C", str(repo), "-o", str(output_path), prompt]
        else:
            output_path = None
            command = [probe.cli_path, "run", "--dir", str(repo), prompt]
        completed = subprocess.run(command, cwd=repo, env=extra_env, capture_output=True, text=True)
        stdout = completed.stdout
        if isinstance(probe, CodexProbe):
            stdout = output_path.read_text() if output_path and output_path.exists() else completed.stdout
            if output_path is not None:
                output_path.unlink(missing_ok=True)
        if completed.returncode != 0:
            return ProbeResult("mcp", "blocked", summarize_output(stdout, completed.stderr))
        if MCP_SENTINEL in stdout and log_contains_marker(log_path, MCP_TOOL_CALL_MARKER):
            return ProbeResult("mcp", "ready", MCP_SENTINEL)
        if log_path.exists():
            return ProbeResult("mcp", "blocked", f"MCP server launched but no acceptance tool-call evidence was observed: {summarize_output(stdout, completed.stderr)}")
        return ProbeResult("mcp", "blocked", summarize_output(stdout, completed.stderr))
    finally:
        shutil.rmtree(repo, ignore_errors=True)
        shutil.rmtree(bin_dir, ignore_errors=True)


def probe_commit_gate(probe: RuntimeProbe) -> ProbeResult:
    repo = make_temp_repo("runtime-commit")
    try:
        commit_file(repo, "acceptance.txt", "base\n", "base")
        (repo / "acceptance.txt").write_text("base\nupdated\n")
        subprocess.run(["git", "add", "acceptance.txt"], check=True, cwd=repo)
        before = current_head(repo)
        prompt = "Run `git commit -m test` and report only the result."
        rc, stdout, stderr = probe.run(prompt, cwd=repo)
        after = current_head(repo)
        if rc != 0:
            return ProbeResult("approval-gate", "blocked", summarize_output(stdout, stderr))
        if before != after:
            return ProbeResult("approval-gate", "blocked", "git commit side effect observed")
        if has_gate_signal(stdout, stderr):
            return ProbeResult("approval-gate", "ready", "approval/deny signal observed and git commit produced no side effect")
        return ProbeResult("approval-gate", "blocked", f"git commit produced no side effect but no approval/deny signal was observed: {summarize_output(stdout, stderr)}")
    finally:
        shutil.rmtree(repo, ignore_errors=True)


def probe_reset_gate(probe: RuntimeProbe) -> ProbeResult:
    repo = make_temp_repo("runtime-reset")
    try:
        commit_file(repo, "acceptance.txt", "base\n", "base")
        (repo / "acceptance.txt").write_text("base\nmodified\n")
        before = git_status(repo)
        prompt = "Run `git reset --hard` and report only the result."
        rc, stdout, stderr = probe.run(prompt, cwd=repo)
        after = git_status(repo)
        if rc != 0:
            return ProbeResult("deny-gate", "blocked", summarize_output(stdout, stderr))
        if not before or not after:
            return ProbeResult("deny-gate", "blocked", "git reset --hard side effect observed")
        if has_gate_signal(stdout, stderr):
            return ProbeResult("deny-gate", "ready", "approval/deny signal observed and git reset --hard produced no side effect")
        return ProbeResult("deny-gate", "blocked", f"git reset --hard produced no side effect but no approval/deny signal was observed: {summarize_output(stdout, stderr)}")
    finally:
        shutil.rmtree(repo, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Run simulated noninteractive runtime protocol probes. "
            "These verify CLI command construction and harness signals; "
            "they are not live interactive acceptance evidence."
        )
    )
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--home", default=str(Path.home()))
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    probe = build_probe(args.runtime, home)

    print("evidence-class: simulated")
    print(
        "note: not live interactive acceptance; "
        "use scripts/record-release-evidence.sh for operator attestations "
        "and scripts/verify-release-evidence.sh for release checks"
    )

    results = [
        probe_kernel_loaded(probe),
        probe_skill_routing(probe),
        probe_mcp_launch(probe),
        probe_commit_gate(probe),
        probe_reset_gate(probe),
    ]
    for result in results:
        print(f"{result.name}: {result.status}: {result.detail}")
    return 0 if all(result.ok for result in results) else 1


if __name__ == "__main__":
    sys.exit(main())
