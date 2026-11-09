#!/usr/bin/env node
// b-agentic Codex verdict mapper. It normalizes the result of the
// openai/codex-plugin-cc adversarial review into b-review's finding IDs and a
// provisional verdict. The main session applies b-review's blocker taxonomy to
// the provisional classes and owns the final verdict.
//
// Usage: b-codex-verdict.mjs [--round N] [--file PATH]   (stdin when no --file)
// Input: the plugin's structured JSON ({verdict, findings[]}) or its rendered
// text (`Verdict: needs-attention` plus `- [severity] title (file:lines)`).
// Exit: 0 mapped, 3 void (no usable verdict), 2 invalid input. Fail closed: an
// unknown shape never becomes an approval.
import { readFileSync, realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";

export const SEVERITIES = ["critical", "high", "medium", "low"];
const CODEX_VERDICTS = ["approve", "needs-attention"];
const BLOCKING_SEVERITIES = new Set(["critical", "high"]);

function normalizeFinding(raw, index) {
  if (!raw || typeof raw !== "object") {
    throw new Error(`finding ${index + 1}: expected an object`);
  }
  const severity = String(raw.severity ?? "").toLowerCase();
  if (!SEVERITIES.includes(severity)) {
    throw new Error(
      `finding ${index + 1}: unknown severity ${JSON.stringify(raw.severity)}`,
    );
  }
  const title = typeof raw.title === "string" ? raw.title.trim() : "";
  if (!title) throw new Error(`finding ${index + 1}: missing title`);
  const number = (value) => (Number.isInteger(value) ? value : null);
  return {
    severity,
    title,
    file: typeof raw.file === "string" && raw.file ? raw.file : null,
    line_start: number(raw.line_start),
    line_end: number(raw.line_end),
    confidence: typeof raw.confidence === "number" ? raw.confidence : null,
    recommendation:
      typeof raw.recommendation === "string" ? raw.recommendation : null,
    body: typeof raw.body === "string" ? raw.body : null,
  };
}

// Rendered form: `Verdict: needs-attention` and `- [high] Title (path:12-18)`.
// Strict and fail-closed: a conflicting or repeated verdict, or any line that
// looks like a finding but cannot be normalized, is an error, never a silent
// drop. Prefer the structured JSON form.
const FINDING_LINE =
  /^\s*[-*]\s*\[(critical|high|medium|low)\]\s+(.*?)(?:\s+\(([^()\s]+?)(?::(\d+)(?:-(\d+))?)?\))?\s*$/i;
const FINDING_SHAPED = /^\s*(?:[-*]|\d+[.)])\s*\[[^\]]*\]/;
const STRAY_SEVERITY = /\[(?:critical|high|medium|low)\]/i;

export function parseText(text) {
  const verdicts = [...text.matchAll(/^\s*Verdict:\s*(.*?)\s*$/gim)].map(
    (match) => match[1].toLowerCase(),
  );
  const unknown = verdicts.find((value) => !CODEX_VERDICTS.includes(value));
  if (unknown !== undefined) {
    throw new Error(
      `unrecognized verdict in rendered text: ${JSON.stringify(unknown)}`,
    );
  }
  if (verdicts.length > 1) {
    throw new Error(
      new Set(verdicts).size > 1
        ? "conflicting verdicts in rendered text"
        : "repeated verdict line in rendered text",
    );
  }
  const findings = [];
  for (const line of text.split("\n")) {
    const match = line.match(FINDING_LINE);
    if (!match) {
      if (FINDING_SHAPED.test(line) || STRAY_SEVERITY.test(line)) {
        throw new Error(
          `unparseable finding line in rendered text: ${JSON.stringify(line.trim().slice(0, 120))}`,
        );
      }
      continue;
    }
    findings.push({
      severity: match[1].toLowerCase(),
      title: match[2],
      file: match[3] ?? null,
      line_start: match[4] ? Number(match[4]) : null,
      line_end: match[5]
        ? Number(match[5])
        : match[4]
          ? Number(match[4])
          : null,
    });
  }
  return { verdict: verdicts[0], findings };
}

export function parseInput(text) {
  const trimmed = text.trim();
  if (trimmed.startsWith("{")) {
    try {
      return JSON.parse(trimmed);
    } catch (error) {
      throw new Error(
        `input looks like JSON but does not parse: ${error.message}`,
      );
    }
  }
  return parseText(text);
}

export function mapVerdict(input, round = 1) {
  const codexVerdict =
    typeof input?.verdict === "string" ? input.verdict.toLowerCase() : null;
  if (!CODEX_VERDICTS.includes(codexVerdict)) {
    throw new Error(
      `unknown or missing Codex verdict: ${JSON.stringify(input?.verdict)}`,
    );
  }
  if (!Array.isArray(input.findings)) {
    throw new Error("findings must be an array");
  }
  const findings = input.findings
    .map(normalizeFinding)
    .map((finding, index) => ({
      id: `R${round}-${index + 1}`,
      ...finding,
      provisional_class: BLOCKING_SEVERITIES.has(finding.severity)
        ? "blocker"
        : "follow-up",
    }));
  const reasons = [];
  let provisional;
  if (findings.some((finding) => finding.provisional_class === "blocker")) {
    provisional = "NEEDS FIXES";
    if (codexVerdict === "approve")
      reasons.push(
        "Codex approved but reported critical or high findings; findings win",
      );
  } else if (findings.length > 0) {
    provisional = "READY WITH FOLLOW-UPS";
    if (codexVerdict === "approve")
      reasons.push("Codex approved with medium or low findings");
  } else if (codexVerdict === "approve") {
    provisional = "READY FOR PR";
  } else {
    provisional = "VOID";
    reasons.push(
      "Codex asked for attention but returned no findings; the review is void, rerun or ask",
    );
  }
  return {
    schema: "b-codex-verdict/1",
    round,
    codex_verdict: codexVerdict,
    provisional_verdict: provisional,
    reasons,
    note: "critical and high findings are provisional blockers unless later disproved with evidence; medium and low findings are follow-ups unless they fall in a b-review blocker class. The main session owns the final verdict.",
    summary: typeof input.summary === "string" ? input.summary : null,
    next_steps: Array.isArray(input.next_steps)
      ? input.next_steps.filter((item) => typeof item === "string")
      : [],
    findings,
  };
}

function main(argv) {
  let round = 1;
  let file = null;
  for (let index = 0; index < argv.length; index++) {
    if (argv[index] === "--round") {
      round = Number(argv[++index]);
      if (!Number.isInteger(round) || round < 1)
        throw new Error("--round needs a positive integer");
    } else if (argv[index] === "--file") {
      file = argv[++index];
      if (!file) throw new Error("--file needs a path");
    } else {
      throw new Error(`unknown argument: ${argv[index]}`);
    }
  }
  const result = mapVerdict(parseInput(readFileSync(file ?? 0, "utf8")), round);
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  return result.provisional_verdict === "VOID" ? 3 : 0;
}

function isEntryPoint() {
  try {
    return (
      import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
    );
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(
      `${error instanceof Error ? error.message : String(error)}\n`,
    );
    process.exitCode = 2;
  }
}
