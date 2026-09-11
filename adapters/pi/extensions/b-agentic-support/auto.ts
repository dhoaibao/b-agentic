import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const AUTO_MODE_ENTRY_TYPE = "b-agentic-auto-mode";

type AutoModePreference = { enabled: boolean };

export function autoModePath(): string {
  return join(
    process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent"),
    "b-agentic",
    "auto-mode.json",
  );
}

export function loadAutoModePreference(
  path = autoModePath(),
): boolean | undefined {
  if (!existsSync(path)) return undefined;
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
      return undefined;
    const enabled = (parsed as Partial<AutoModePreference>).enabled;
    return typeof enabled === "boolean" ? enabled : undefined;
  } catch {
    return undefined;
  }
}

export function saveAutoModePreference(
  enabled: boolean,
  path = autoModePath(),
): void {
  mkdirSync(dirname(path), { recursive: true });
  const temporaryPath = `${path}.${process.pid}.tmp`;
  writeFileSync(
    temporaryPath,
    `${JSON.stringify({ enabled } satisfies AutoModePreference, null, 2)}\n`,
    "utf8",
  );
  renameSync(temporaryPath, path);
}

export function parseAutoMode(value: unknown): boolean | undefined {
  if (typeof value === "boolean") return value;
  if (typeof value !== "string") return undefined;
  const normalized = value.trim().toLowerCase();
  if (["on", "enable", "enabled", "true", "yes"].includes(normalized))
    return true;
  if (["off", "disable", "disabled", "false", "no"].includes(normalized))
    return false;
  return undefined;
}

export function latestAutoModeState(entries: unknown[]): boolean | undefined {
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    const record = entry as Record<string, unknown>;
    if (record.type !== "custom" || record.customType !== AUTO_MODE_ENTRY_TYPE)
      continue;
    const data = record.data;
    if (!data || typeof data !== "object" || Array.isArray(data)) continue;
    if (typeof (data as Record<string, unknown>).enabled === "boolean") {
      return (data as Record<string, unknown>).enabled as boolean;
    }
  }
  return undefined;
}
