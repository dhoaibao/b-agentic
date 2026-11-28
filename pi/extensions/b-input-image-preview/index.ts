// Input image preview: show a framed thumbnail of image paths typed or pasted
// into the chat input, in a widget directly above the editor, before sending.
//
// Display-only: it never touches the editor, its text, or what is submitted.
// - Image paths in the editor (a Ctrl+V clipboard image, a dragged file, or a typed
//   path) get a thumbnail; the path text itself stays in the input as Pi inserts it.
// - Clicking a preview (fullscreen tuiMode routes mouse events) or running
//   `/b-image [n]` opens a centered popup (overlay) with the image at its natural
//   size (up to 2x, capped to the terminal); Esc, Enter, q, Space or a click on
//   the popup closes it. `/b-image` opens the n-th image of the most recent preview
//   (default: the first), because the command line itself clears the input. The
//   inline thumbnail hides while the popup is open, because Kitty draws images
//   above text. The popup needs the Kitty graphics protocol; elsewhere it shows a
//   short text notice instead.
// - Where the terminal cannot show images, pi-tui's Image component falls back
//   to a one-line text label.
// - Interactive TUI only: outside it, and with PI_INPUT_IMAGE_PREVIEW=off, the
//   extension registers nothing (no widget or command).
//
// Set PI_INPUT_IMAGE_PREVIEW=off to disable it without removing the file.
import { constants, existsSync, lstatSync } from "node:fs";
import { lstat, open } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { Worker, type WorkerOptions } from "node:worker_threads";
import type {
  ExtensionAPI,
  ExtensionContext,
  Theme,
} from "@earendil-works/pi-coding-agent";
import { getPackageDir } from "@earendil-works/pi-coding-agent";
import {
  allocateImageId,
  deleteKittyImage,
  getCapabilities,
  getCellDimensions,
  getImageDimensions,
  Image,
  matchesKey,
  truncateToWidth,
  visibleWidth,
  type Component,
  type ImageDimensions,
  type TUI,
  type TuiMouseEvent,
  type TuiMouseEventResult,
} from "@earendil-works/pi-tui";

const WIDGET_KEY = "input-image-preview";
const IMAGE_EXT = /\.(png|jpe?g|gif|webp)$/i;
const MAX_IMAGES = 4;
const MAX_BYTES = 20 * 1024 * 1024;
const MAX_WIDTH_CELLS = 36;
const MAX_HEIGHT_CELLS = 7;

/**
 * One popup at a time. "loading" reserves the slot while the image is read; "open" also hides
 * the inline thumbnail so it cannot draw over the popup. Each operation holds an ownership
 * token: only the current owner may move or release the slot, so a stale operation from a
 * replaced session cannot clear a newer popup's reservation.
 */
export class PopupSlot {
  state: "idle" | "loading" | "open" = "idle";
  private owner: symbol | undefined;
  private closer: (() => void) | undefined;

  acquire(): symbol | undefined {
    if (this.state !== "idle") return undefined;
    this.state = "loading";
    this.owner = Symbol("popup");
    return this.owner;
  }

  open(token: symbol): boolean {
    if (this.owner !== token) return false;
    this.state = "open";
    return true;
  }

  /** Register how to close the open popup, so a session shutdown can finish it. */
  onClose(token: symbol, close: () => void): void {
    if (this.owner === token) this.closer = close;
  }

  /** Returns true when `token` still owned the slot and it was released. */
  release(token: symbol): boolean {
    if (this.owner !== token) return false;
    this.state = "idle";
    this.owner = undefined;
    this.closer = undefined;
    return true;
  }

  /**
   * Session shutdown: finish the open popup, then invalidate every outstanding operation.
   * Pi hides an overlay on session teardown without completing its custom() promise or
   * disposing its component, so the command awaiting it would never settle.
   */
  reset(): void {
    const close = this.closer;
    this.state = "idle";
    this.owner = undefined;
    this.closer = undefined;
    try {
      close?.();
    } catch {
      // The host may already be tearing the UI down.
    }
  }
}

const popup = new PopupSlot();

// Path Pi writes for a Ctrl+V clipboard image: <tmpdir>/pi-clipboard-<uuid>.<ext>
const CLIPBOARD_IMAGE = /^pi-clipboard-[0-9a-f-]{36}\.(png|jpe?g|gif|webp)$/i;

/** Pi's own temp name is a long uuid, so previews label it by position instead. */
export function isClipboardImagePath(file: string): boolean {
  return (
    path.dirname(file) === path.resolve(os.tmpdir()) &&
    CLIPBOARD_IMAGE.test(path.basename(file))
  );
}

/** Strip ANSI/OSC/CSI escape sequences and C0/C1 control chars before terminal display. */
// eslint-disable-next-line no-control-regex
const OSC_OR_STRING_SEQ =
  /\u001b(?:\][^\u0007\u001b]*(?:\u0007|\u001b\\)|[PX^_][^\u001b]*\u001b\\)/g;
// eslint-disable-next-line no-control-regex
const CSI_OR_ESC_SEQ = /(?:\u001b\[|\u009b)[0-?]*[ -/]*[@-~]|\u001b[@-Z\\-_]/g;
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f]/g;

export function sanitizeTerminalText(text: string): string {
  return text
    .replace(OSC_OR_STRING_SEQ, "")
    .replace(CSI_OR_ESC_SEQ, "")
    .replace(CONTROL_CHARS, "");
}

/** Short label for a preview: "Image n" for Pi's clipboard temp files, else the sanitized file name. */
export function imageLabel(file: string, index: number): string {
  return isClipboardImagePath(file)
    ? `Image ${index + 1}`
    : sanitizeTerminalText(path.basename(file));
}

export function previewErrorMessage(file: string): string {
  return `Cannot preview ${sanitizeTerminalText(path.basename(file))}: missing, too large, or not a supported image`;
}

export function imageNotFoundMessage(raw: string, available: number): string {
  if (available === 0) {
    return "No image preview yet: put an image path in the input first";
  }
  const safe = sanitizeTerminalText(raw.trim());
  return `No image ${safe || 1} in the latest preview (${available} available)`;
}

export function hasRegisteredCommand(
  commands: readonly { name: string; source?: string }[],
  name: string,
): boolean {
  const prefix = `${name}:`;
  return commands.some(
    (cmd) =>
      (cmd.source === "extension" || cmd.source === "prompt") &&
      (cmd.name === name || cmd.name.startsWith(prefix)),
  );
}

/**
 * The image paths of the most recent non-empty preview, for `/b-image [n]`: submitting the
 * command clears the input, so the paths are remembered here. Paths only, never image data.
 */
export class RecentImages {
  private files: string[] = [];

  set(files: readonly string[]): void {
    if (files.length > 0) this.files = [...files];
  }

  /** 1-based; the first image when `n` is omitted. */
  get(n?: number): string | undefined {
    return this.files[(n ?? 1) - 1];
  }

  get size(): number {
    return this.files.length;
  }
}

const recent = new RecentImages();

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function sniffMime(buf: Buffer): string | null {
  if (
    buf.length >= 8 &&
    buf
      .subarray(0, 8)
      .equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
  ) {
    return "image/png";
  }
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff)
    return "image/jpeg";
  if (buf.length >= 6 && buf.subarray(0, 4).toString("latin1") === "GIF8")
    return "image/gif";
  if (
    buf.length >= 12 &&
    buf.subarray(0, 4).toString("latin1") === "RIFF" &&
    buf.subarray(8, 12).toString("latin1") === "WEBP"
  ) {
    return "image/webp";
  }
  return null;
}

// Pi 1.6.1 inserts clipboard file paths unquoted and newline-separated, sometimes with
// literal backslashes, apostrophes, embedded extensions, or spaces. Prefer exact existing
// paths on disk (preserving ".." across symlink parents via lstat, which never opens FIFOs)
// before escaped/tokenized fallbacks, scanning left-to-right with bounded probing and never
// collapsing ".." lexically.
const ANCHORED_START = /^@?(?:\/|~\/|\.{1,2}\/)/;
const ANCHORED_AT_START =
  /^(@?(?:\/|~\/|\.{1,2}\/)(?:(?!\s@?(?:\/|~\/|\.{1,2}\/))[^\r\n])*?\.(?:png|jpe?g|gif|webp))(?=$|\s)/i;
const EXT_END_MATCH = /\.(?:png|jpe?g|gif|webp)(?=$|\s)/gi;
const QUOTED_DOUBLE_AT_START = /^"([^"]+)"/;
const QUOTED_SINGLE_AT_START = /^'([^']+)'/;
const BARE_TOKEN_AT_START = /^((?:\\ |\S)+)/;
const MAX_PATH_CHARS = 4096;
const MAX_ANCHORED_EXTS = 4;
const MAX_STAT_PROBES = 64;
const MAX_SCAN_CHARS = 64 * 1024;
const ASYNC_CHUNK_CHARS = 4096;

function stripLeadingAt(rawPath: string): string {
  return rawPath.startsWith("@") ? rawPath.slice(1) : rawPath;
}

function toLiteralAbsolute(rawPath: string, cwd: string): string | null {
  const raw = stripLeadingAt(rawPath);
  if (!IMAGE_EXT.test(raw)) return null;
  if (raw.startsWith("~/")) {
    const home = os.homedir().replace(/\/+$/, "") || "/";
    return `${home}/${raw.slice(2)}`;
  }
  if (path.isAbsolute(raw)) return raw;
  const base = cwd.replace(/\/+$/, "") || "/";
  return `${base}/${raw.replace(/^\.\//, "")}`;
}

function pathExistsSync(candidate: string): boolean {
  try {
    lstatSync(candidate);
    return true;
  } catch {
    return false;
  }
}

async function pathExistsAsync(candidate: string): Promise<boolean> {
  try {
    await lstat(candidate);
    return true;
  } catch {
    return false;
  }
}

function pushResolved(found: string[], resolved: string | null): void {
  if (resolved && !found.includes(resolved)) found.push(resolved);
}

function anchoredCandidateEnds(rest: string): number[] {
  if (!ANCHORED_START.test(rest)) return [];
  const window =
    rest.length > MAX_PATH_CHARS ? rest.slice(0, MAX_PATH_CHARS) : rest;
  const ends: number[] = [];
  for (const match of window.matchAll(EXT_END_MATCH)) {
    if (match.index === undefined) continue;
    ends.push(match.index + match[0].length);
    if (ends.length >= MAX_ANCHORED_EXTS) break;
  }
  return ends;
}

function matchExistingAnchoredSync(
  rest: string,
  cwd: string,
  exists: (candidate: string) => boolean,
): { resolved: string; length: number } | null {
  const ends = anchoredCandidateEnds(rest);
  for (let i = ends.length - 1; i >= 0; i -= 1) {
    const slice = rest.slice(0, ends[i]);
    const literal = toLiteralAbsolute(slice, cwd);
    if (literal && exists(literal)) {
      return { resolved: literal, length: slice.length };
    }
  }
  for (let i = ends.length - 1; i >= 0; i -= 1) {
    const slice = rest.slice(0, ends[i]);
    if (!slice.includes("\\ ")) continue;
    const unescaped = slice.replace(/\\ /g, " ");
    const literal = toLiteralAbsolute(unescaped, cwd);
    if (literal && exists(literal)) {
      return { resolved: literal, length: slice.length };
    }
  }
  return null;
}

async function matchExistingAnchoredAsync(
  rest: string,
  cwd: string,
  exists: (candidate: string) => Promise<boolean>,
): Promise<{ resolved: string; length: number } | null> {
  const ends = anchoredCandidateEnds(rest);
  for (let i = ends.length - 1; i >= 0; i -= 1) {
    const slice = rest.slice(0, ends[i]);
    const literal = toLiteralAbsolute(slice, cwd);
    if (literal && (await exists(literal))) {
      return { resolved: literal, length: slice.length };
    }
  }
  for (let i = ends.length - 1; i >= 0; i -= 1) {
    const slice = rest.slice(0, ends[i]);
    if (!slice.includes("\\ ")) continue;
    const unescaped = slice.replace(/\\ /g, " ");
    const literal = toLiteralAbsolute(unescaped, cwd);
    if (literal && (await exists(literal))) {
      return { resolved: literal, length: slice.length };
    }
  }
  return null;
}

function makeBoundedExistsSync(): (candidate: string) => boolean {
  const cache = new Map<string, boolean>();
  let remaining = MAX_STAT_PROBES;
  return (candidate: string) => {
    if (candidate.length > MAX_PATH_CHARS) return false;
    const hit = cache.get(candidate);
    if (hit !== undefined) return hit;
    if (remaining <= 0) return false;
    remaining -= 1;
    const ok = pathExistsSync(candidate);
    cache.set(candidate, ok);
    return ok;
  };
}

function makeBoundedExistsAsync(): (candidate: string) => Promise<boolean> {
  const cache = new Map<string, boolean>();
  let remaining = MAX_STAT_PROBES;
  return async (candidate: string) => {
    if (candidate.length > MAX_PATH_CHARS) return false;
    const hit = cache.get(candidate);
    if (hit !== undefined) return hit;
    if (remaining <= 0) return false;
    remaining -= 1;
    const ok = await pathExistsAsync(candidate);
    cache.set(candidate, ok);
    return ok;
  };
}

function yieldToLoop(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function sliceScanBound(text: string): {
  scanText: string;
  scanLimit: number;
  truncatedLine: boolean;
} {
  if (text.length <= MAX_SCAN_CHARS) {
    return { scanText: text, scanLimit: text.length, truncatedLine: false };
  }
  if (
    text[MAX_SCAN_CHARS] === "\n" ||
    (text[MAX_SCAN_CHARS] === "\r" && text[MAX_SCAN_CHARS + 1] === "\n")
  ) {
    return {
      scanText: text.slice(0, MAX_SCAN_CHARS),
      scanLimit: MAX_SCAN_CHARS,
      truncatedLine: false,
    };
  }
  const nl = text.lastIndexOf("\n", MAX_SCAN_CHARS - 1);
  if (nl !== -1) {
    return {
      scanText: text.slice(0, nl + 1),
      scanLimit: nl + 1,
      truncatedLine: false,
    };
  }
  // Single >64 KiB line: trim start limit before any partial token, but keep lookahead
  // up to MAX_PATH_CHARS so an existing spaced path (e.g. `shot.png copy.png`) that
  // started before the cutoff is not misread as `shot.png`.
  let cut = MAX_SCAN_CHARS;
  if (!/\s/.test(text[cut])) {
    while (cut > 0 && !/\s/.test(text[cut - 1])) cut -= 1;
  }
  return {
    scanText: text.slice(
      0,
      Math.min(text.length, MAX_SCAN_CHARS + MAX_PATH_CHARS),
    ),
    scanLimit: cut,
    truncatedLine: true,
  };
}

export function extractImagePaths(text: string, cwd: string): string[] {
  const exists = makeBoundedExistsSync();
  const { scanText, scanLimit, truncatedLine } = sliceScanBound(text);
  const found: string[] = [];
  if (truncatedLine) {
    let pos = 0;
    while (pos < scanLimit && found.length < MAX_IMAGES) {
      if (/\s/.test(scanText[pos])) {
        pos += 1;
        continue;
      }
      const rest = scanText.slice(pos);
      if (rest[0] === '"') {
        const quoted = QUOTED_DOUBLE_AT_START.exec(rest);
        if (quoted && pos + quoted[0].length <= scanLimit) {
          pushResolved(found, toLiteralAbsolute(quoted[1], cwd));
          pos += quoted[0].length;
          continue;
        }
      } else if (rest[0] === "'") {
        const quoted = QUOTED_SINGLE_AT_START.exec(rest);
        if (quoted && pos + quoted[0].length <= scanLimit) {
          pushResolved(found, toLiteralAbsolute(quoted[1], cwd));
          pos += quoted[0].length;
          continue;
        }
      }
      const existing = matchExistingAnchoredSync(rest, cwd, exists);
      if (existing) {
        pushResolved(found, existing.resolved);
        pos += existing.length;
        continue;
      }
      const anchored = ANCHORED_AT_START.exec(rest);
      if (anchored && pos + anchored[0].length <= scanLimit) {
        pushResolved(
          found,
          toLiteralAbsolute(anchored[1].replace(/\\ /g, " "), cwd),
        );
        pos += anchored[0].length;
        continue;
      }
      const bare = BARE_TOKEN_AT_START.exec(rest);
      if (bare) {
        if (pos + bare[0].length <= scanLimit) {
          const literal = toLiteralAbsolute(bare[1], cwd);
          const resolved =
            literal && exists(literal)
              ? literal
              : toLiteralAbsolute(bare[1].replace(/\\ /g, " "), cwd);
          pushResolved(found, resolved);
        }
        pos += bare[0].length;
        continue;
      }
      pos += 1;
    }
    return found;
  }
  for (const line of scanText.split(/\r?\n/)) {
    if (found.length >= MAX_IMAGES) break;
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (trimmed.length <= MAX_PATH_CHARS) {
      const whole = toLiteralAbsolute(trimmed, cwd);
      if (whole && exists(whole)) {
        pushResolved(found, whole);
        continue;
      }
    }
    let pos = 0;
    while (pos < line.length && found.length < MAX_IMAGES) {
      if (/\s/.test(line[pos])) {
        pos += 1;
        continue;
      }
      const rest = line.slice(pos);
      if (rest[0] === '"') {
        const quoted = QUOTED_DOUBLE_AT_START.exec(rest);
        if (quoted) {
          pushResolved(found, toLiteralAbsolute(quoted[1], cwd));
          pos += quoted[0].length;
          continue;
        }
      } else if (rest[0] === "'") {
        const quoted = QUOTED_SINGLE_AT_START.exec(rest);
        if (quoted) {
          pushResolved(found, toLiteralAbsolute(quoted[1], cwd));
          pos += quoted[0].length;
          continue;
        }
      }
      const existing = matchExistingAnchoredSync(rest, cwd, exists);
      if (existing) {
        pushResolved(found, existing.resolved);
        pos += existing.length;
        continue;
      }
      const anchored = ANCHORED_AT_START.exec(rest);
      if (anchored) {
        pushResolved(
          found,
          toLiteralAbsolute(anchored[1].replace(/\\ /g, " "), cwd),
        );
        pos += anchored[0].length;
        continue;
      }
      const bare = BARE_TOKEN_AT_START.exec(rest);
      if (bare) {
        const literal = toLiteralAbsolute(bare[1], cwd);
        const resolved =
          literal && exists(literal)
            ? literal
            : toLiteralAbsolute(bare[1].replace(/\\ /g, " "), cwd);
        pushResolved(found, resolved);
        pos += bare[0].length;
        continue;
      }
      pos += 1;
    }
  }
  return found;
}

export async function extractImagePathsAsync(
  text: string,
  cwd: string,
  isCancelled?: () => boolean,
): Promise<string[]> {
  const exists = makeBoundedExistsAsync();
  const { scanText, scanLimit, truncatedLine } = sliceScanBound(text);
  const found: string[] = [];
  if (truncatedLine) {
    let pos = 0;
    let scannedSinceYield = 0;
    while (pos < scanLimit && found.length < MAX_IMAGES) {
      if (isCancelled?.()) return [];
      if (scannedSinceYield >= ASYNC_CHUNK_CHARS) {
        scannedSinceYield = 0;
        await yieldToLoop();
        if (isCancelled?.()) return [];
      }
      if (/\s/.test(scanText[pos])) {
        pos += 1;
        scannedSinceYield += 1;
        continue;
      }
      const rest = scanText.slice(pos);
      if (rest[0] === '"') {
        const quoted = QUOTED_DOUBLE_AT_START.exec(rest);
        if (quoted && pos + quoted[0].length <= scanLimit) {
          pushResolved(found, toLiteralAbsolute(quoted[1], cwd));
          pos += quoted[0].length;
          scannedSinceYield += quoted[0].length;
          continue;
        }
      } else if (rest[0] === "'") {
        const quoted = QUOTED_SINGLE_AT_START.exec(rest);
        if (quoted && pos + quoted[0].length <= scanLimit) {
          pushResolved(found, toLiteralAbsolute(quoted[1], cwd));
          pos += quoted[0].length;
          scannedSinceYield += quoted[0].length;
          continue;
        }
      }
      const existing = await matchExistingAnchoredAsync(rest, cwd, exists);
      if (existing) {
        pushResolved(found, existing.resolved);
        pos += existing.length;
        scannedSinceYield += existing.length;
        continue;
      }
      const anchored = ANCHORED_AT_START.exec(rest);
      if (anchored && pos + anchored[0].length <= scanLimit) {
        pushResolved(
          found,
          toLiteralAbsolute(anchored[1].replace(/\\ /g, " "), cwd),
        );
        pos += anchored[0].length;
        scannedSinceYield += anchored[0].length;
        continue;
      }
      const bare = BARE_TOKEN_AT_START.exec(rest);
      if (bare) {
        if (pos + bare[0].length <= scanLimit) {
          const literal = toLiteralAbsolute(bare[1], cwd);
          const resolved =
            literal && (await exists(literal))
              ? literal
              : toLiteralAbsolute(bare[1].replace(/\\ /g, " "), cwd);
          pushResolved(found, resolved);
        }
        pos += bare[0].length;
        scannedSinceYield += bare[0].length;
        continue;
      }
      pos += 1;
      scannedSinceYield += 1;
    }
    return found;
  }
  let lineStart = 0;
  let scannedSinceYield = 0;
  while (lineStart <= scanText.length && found.length < MAX_IMAGES) {
    if (isCancelled?.()) return [];
    const nl = scanText.indexOf("\n", lineStart);
    const lineEnd = nl === -1 ? scanText.length : nl;
    let line = scanText.slice(lineStart, lineEnd);
    if (line.endsWith("\r")) line = line.slice(0, -1);
    lineStart = nl === -1 ? scanText.length + 1 : nl + 1;

    const trimmed = line.trim();
    if (!trimmed) {
      scannedSinceYield += line.length + 1;
      if (scannedSinceYield >= ASYNC_CHUNK_CHARS) {
        scannedSinceYield = 0;
        await yieldToLoop();
        if (isCancelled?.()) return [];
      }
      continue;
    }
    if (trimmed.length <= MAX_PATH_CHARS) {
      const whole = toLiteralAbsolute(trimmed, cwd);
      if (whole && (await exists(whole))) {
        pushResolved(found, whole);
        continue;
      }
    }
    let pos = 0;
    while (pos < line.length && found.length < MAX_IMAGES) {
      if (isCancelled?.()) return [];
      if (scannedSinceYield >= ASYNC_CHUNK_CHARS) {
        scannedSinceYield = 0;
        await yieldToLoop();
        if (isCancelled?.()) return [];
      }
      if (/\s/.test(line[pos])) {
        pos += 1;
        scannedSinceYield += 1;
        continue;
      }
      const rest = line.slice(pos);
      if (rest[0] === '"') {
        const quoted = QUOTED_DOUBLE_AT_START.exec(rest);
        if (quoted) {
          pushResolved(found, toLiteralAbsolute(quoted[1], cwd));
          pos += quoted[0].length;
          scannedSinceYield += quoted[0].length;
          continue;
        }
      } else if (rest[0] === "'") {
        const quoted = QUOTED_SINGLE_AT_START.exec(rest);
        if (quoted) {
          pushResolved(found, toLiteralAbsolute(quoted[1], cwd));
          pos += quoted[0].length;
          scannedSinceYield += quoted[0].length;
          continue;
        }
      }
      const existing = await matchExistingAnchoredAsync(rest, cwd, exists);
      if (existing) {
        pushResolved(found, existing.resolved);
        pos += existing.length;
        scannedSinceYield += existing.length;
        continue;
      }
      const anchored = ANCHORED_AT_START.exec(rest);
      if (anchored) {
        pushResolved(
          found,
          toLiteralAbsolute(anchored[1].replace(/\\ /g, " "), cwd),
        );
        pos += anchored[0].length;
        scannedSinceYield += anchored[0].length;
        continue;
      }
      const bare = BARE_TOKEN_AT_START.exec(rest);
      if (bare) {
        const literal = toLiteralAbsolute(bare[1], cwd);
        const resolved =
          literal && (await exists(literal))
            ? literal
            : toLiteralAbsolute(bare[1].replace(/\\ /g, " "), cwd);
        pushResolved(found, resolved);
        pos += bare[0].length;
        scannedSinceYield += bare[0].length;
        continue;
      }
      pos += 1;
      scannedSinceYield += 1;
    }
  }
  return found;
}

interface Loaded {
  data: string;
  mime: string;
  dims: ImageDimensions | null;
  renderDims: ImageDimensions | null;
  meta: string;
}

/**
 * Read at most MAX_BYTES from one open handle, so a file that grows or is swapped cannot bypass the cap.
 * O_NONBLOCK keeps the open from waiting on a FIFO with no writer; isFile() then rejects it.
 */
async function readBounded(file: string): Promise<Buffer | null> {
  const handle = await open(
    file,
    constants.O_RDONLY | (constants.O_NONBLOCK ?? 0),
  );
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.size === 0 || info.size > MAX_BYTES) return null;
    const buf = Buffer.allocUnsafe(MAX_BYTES + 1);
    let total = 0;
    while (total < buf.length) {
      const { bytesRead } = await handle.read(
        buf,
        total,
        buf.length - total,
        total,
      );
      if (bytesRead === 0) break;
      total += bytesRead;
    }
    return total === 0 || total > MAX_BYTES ? null : buf.subarray(0, total);
  } finally {
    await handle.close();
  }
}

const THUMB_MAX_DIM = 640;
const POPUP_MAX_DIM = 1600;
const THUMB_MAX_PNG_BYTES = 2 * 1024 * 1024;
const POPUP_MAX_PNG_BYTES = 8 * 1024 * 1024;
const MAX_SOURCE_DIM = 8192;
const MAX_SOURCE_PIXELS = 25_000_000;
const MAX_INFLIGHT_WORKERS = 4;

const activeWorkers = new Set<Worker>();
let activeWorkerSlots = 0;
const workerWaitQueue: Array<() => void> = [];

export function cancelAllImageWorkers(): void {
  while (workerWaitQueue.length > 0) {
    const wake = workerWaitQueue.shift();
    wake?.();
  }
  for (const worker of [...activeWorkers]) {
    activeWorkers.delete(worker);
    void worker.terminate().catch(() => undefined);
  }
}

async function acquireWorkerSlot(signal?: AbortSignal): Promise<boolean> {
  if (signal?.aborted) return false;
  if (activeWorkerSlots < MAX_INFLIGHT_WORKERS) {
    activeWorkerSlots += 1;
    return true;
  }
  return await new Promise<boolean>((resolve) => {
    let settled = false;
    const wake = () => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener("abort", onAbort);
      if (signal?.aborted) {
        resolve(false);
        return;
      }
      if (activeWorkerSlots < MAX_INFLIGHT_WORKERS) {
        activeWorkerSlots += 1;
        resolve(true);
      } else {
        resolve(false);
      }
    };
    const onAbort = () => {
      const idx = workerWaitQueue.indexOf(wake);
      if (idx !== -1) workerWaitQueue.splice(idx, 1);
      wake();
    };
    signal?.addEventListener("abort", onAbort, { once: true });
    workerWaitQueue.push(wake);
  });
}

function releaseWorkerSlot(): void {
  activeWorkerSlots = Math.max(0, activeWorkerSlots - 1);
  while (
    activeWorkerSlots < MAX_INFLIGHT_WORKERS &&
    workerWaitQueue.length > 0
  ) {
    const wake = workerWaitQueue.shift();
    wake?.();
  }
}

const IMAGE_PROCESS_WORKER = `
const { parentPort, workerData } = require("node:worker_threads");
(async () => {
  const codingAgent = await import(workerData.codingAgentUrl);
  let data = workerData.rawBase64;
  let mime = workerData.rawMime;
  if (workerData.needsResize) {
    const resizeCore = await import(workerData.resizeCoreUrl);
    const resized = await resizeCore.resizeImageInProcess(
      new Uint8Array(Buffer.from(data, "base64")),
      mime,
      {
        maxWidth: workerData.maxWidth,
        maxHeight: workerData.maxHeight,
        maxBytes: workerData.maxOutputBytes,
      },
    );
    if (!resized) {
      parentPort.postMessage({ ok: true, res: null });
      return;
    }
    data = resized.data;
    mime = resized.mimeType;
  }
  if (mime !== "image/png") {
    const converted = await codingAgent.convertToPng(data, mime);
    if (!converted) {
      parentPort.postMessage({ ok: true, res: null });
      return;
    }
    data = converted.data;
    mime = converted.mimeType;
  }
  parentPort.postMessage({ ok: true, res: { data, mimeType: mime } });
})().catch((err) => {
  parentPort.postMessage({ ok: false, error: err instanceof Error ? err.message : String(err) });
});
`;

type WorkerFactory = (code: string, options: WorkerOptions) => Worker;

async function processImageInWorker(
  input: {
    rawBase64: string;
    rawMime: string;
    needsResize: boolean;
    maxWidth: number;
    maxHeight: number;
    maxOutputBytes: number;
  },
  createWorker: WorkerFactory = (code, options) => new Worker(code, options),
  signal?: AbortSignal,
): Promise<{ data: string; mimeType: string } | null> {
  if (!(await acquireWorkerSlot(signal))) return null;
  let worker: Worker | undefined;
  let onAbort: (() => void) | undefined;
  try {
    if (signal?.aborted) return null;
    const pkgDir = getPackageDir();
    const useDist = existsSync(path.join(pkgDir, "dist", "index.js"));
    const sub = useDist ? "dist" : "src";
    const codingAgentUrl = pathToFileURL(
      path.join(pkgDir, sub, useDist ? "index.js" : "index.ts"),
    ).href;
    const resizeCoreUrl = pathToFileURL(
      path.join(
        pkgDir,
        sub,
        "utils",
        useDist ? "image-resize-core.js" : "image-resize-core.ts",
      ),
    ).href;
    worker = createWorker(IMAGE_PROCESS_WORKER, {
      eval: true,
      workerData: { ...input, codingAgentUrl, resizeCoreUrl },
    });
    activeWorkers.add(worker);
    return await new Promise<{ data: string; mimeType: string } | null>(
      (resolve, reject) => {
        let settled = false;
        const done = (val: { data: string; mimeType: string } | null) => {
          if (settled) return;
          settled = true;
          resolve(val);
        };
        const fail = (err: unknown) => {
          if (settled) return;
          settled = true;
          reject(err);
        };
        onAbort = () => {
          fail(new Error("aborted"));
          void worker?.terminate().catch(() => undefined);
        };
        if (signal?.aborted) {
          onAbort();
          return;
        }
        signal?.addEventListener("abort", onAbort, { once: true });
        worker!.on(
          "message",
          (msg: {
            ok?: boolean;
            res?: { data: string; mimeType: string } | null;
            error?: string;
          }) => {
            if (!msg || typeof msg !== "object" || !("ok" in msg)) return;
            if (msg.ok) done(msg.res ?? null);
            else fail(new Error(msg.error ?? "worker image processing failed"));
          },
        );
        worker!.once("error", fail);
        worker!.once("exit", (code) => {
          if (!settled)
            fail(new Error(`image worker exited with code ${code}`));
        });
      },
    );
  } catch {
    // Fail closed off-thread: never fall back to synchronous in-process Photon WASM.
    return null;
  } finally {
    if (onAbort) signal?.removeEventListener("abort", onAbort);
    if (worker) activeWorkers.delete(worker);
    await worker?.terminate().catch(() => undefined);
    releaseWorkerSlot();
  }
}

export interface LoadImageOptions {
  maxWidth?: number;
  maxHeight?: number;
  maxOutputBytes?: number;
  createWorker?: WorkerFactory;
  signal?: AbortSignal;
}

/** Read an image file; null when it is missing, too large, or not a supported image. */
export async function loadImage(
  file: string,
  options: LoadImageOptions = {},
): Promise<Loaded | null> {
  try {
    if (options.signal?.aborted) return null;
    const buf = await readBounded(file);
    if (!buf || options.signal?.aborted) return null;
    const rawMime = sniffMime(buf);
    if (!rawMime) return null;
    const rawBase64 = buf.toString("base64");
    const origDims = getImageDimensions(rawBase64, rawMime);
    let data = rawBase64;
    let mime = rawMime;

    if (getCapabilities().images === "kitty") {
      if (
        !origDims ||
        origDims.widthPx <= 0 ||
        origDims.heightPx <= 0 ||
        origDims.widthPx > MAX_SOURCE_DIM ||
        origDims.heightPx > MAX_SOURCE_DIM ||
        origDims.widthPx * origDims.heightPx > MAX_SOURCE_PIXELS
      ) {
        return null;
      }
      const maxWidth = options.maxWidth ?? POPUP_MAX_DIM;
      const maxHeight = options.maxHeight ?? POPUP_MAX_DIM;
      const maxOutputBytes = options.maxOutputBytes ?? POPUP_MAX_PNG_BYTES;
      const needsResize =
        origDims.widthPx > maxWidth ||
        origDims.heightPx > maxHeight ||
        buf.length > maxOutputBytes;
      if (needsResize || mime !== "image/png") {
        const processed = await processImageInWorker(
          {
            rawBase64,
            rawMime,
            needsResize,
            maxWidth,
            maxHeight,
            maxOutputBytes,
          },
          options.createWorker,
          options.signal,
        );
        if (!processed) return null;
        data = processed.data;
        mime = processed.mimeType;
      }
      if (Buffer.byteLength(data, "base64") > maxOutputBytes) return null;
    }

    const renderDims =
      data === rawBase64 && mime === rawMime
        ? origDims
        : getImageDimensions(data, mime);
    // If EXIF orientation rotated the decoded image 90/270 deg relative to header dims,
    // keep natural sizing orientation aligned with the decoded upright bitmap.
    let dims = origDims;
    if (
      origDims &&
      renderDims &&
      origDims.widthPx > origDims.heightPx !==
        renderDims.widthPx > renderDims.heightPx &&
      origDims.widthPx !== origDims.heightPx &&
      renderDims.widthPx !== renderDims.heightPx
    ) {
      dims = { widthPx: origDims.heightPx, heightPx: origDims.widthPx };
    }

    const meta = [
      dims ? `${dims.widthPx}x${dims.heightPx}` : null,
      formatBytes(buf.length),
    ]
      .filter(Boolean)
      .join(" · ");
    return { data, mime, dims, renderDims, meta };
  } catch {
    return null;
  }
}

function deleteKitty(tui: TUI, id: number | undefined): void {
  if (id === undefined || getCapabilities().images !== "kitty") return;
  try {
    tui.terminal.write(deleteKittyImage(id));
  } catch {
    // Cleanup is best effort.
  }
}

function newImage(
  theme: Theme,
  loaded: Loaded,
  file: string,
  kittyId: number | undefined,
  maxW: number,
  maxH: number,
): Image {
  return new Image(
    loaded.data,
    loaded.mime,
    { fallbackColor: (s: string) => theme.fg("muted", s) },
    {
      maxWidthCells: maxW,
      maxHeightCells: maxH,
      filename: sanitizeTerminalText(path.basename(file)),
      imageId: kittyId,
    },
    loaded.renderDims ?? loaded.dims ?? undefined,
  );
}

/** A horizontal rule with an optional title, fitted to `width` columns. */
function rule(
  theme: Theme,
  width: number,
  title?: string,
  hint?: string,
): string {
  const color = (s: string) => theme.fg("borderMuted", s);
  if (width <= 0) return "";
  if (!title) return color("─".repeat(width));
  const left = `${color("─ ")}${theme.fg("accent", title)}`;
  const right = hint ? theme.fg("dim", ` ${hint} `) : "";
  const used = 3 + visibleWidth(title) + visibleWidth(right);
  const fill = Math.max(0, width - used);
  return truncateToWidth(`${left} ${color("─".repeat(fill))}${right}`, width);
}

type Entry =
  | { status: "loading"; token: symbol; controller: AbortController }
  | {
      status: "ready";
      image: Image;
      mime: string;
      meta: string;
      kittyId?: number;
    }
  | { status: "failed" };

interface Block {
  file: string;
  index: number;
  start: number;
  end: number;
}

export class PreviewWidget implements Component {
  private entries = new Map<string, Entry>();
  private blocks: Block[] = [];
  private disposed = false;
  private lastText: string | undefined;
  private wanted: string[] = [];
  private resolveToken: symbol | undefined;

  constructor(
    private tui: TUI,
    private theme: Theme,
    private getText: () => string,
    private cwd: string,
    private open: (file: string, index: number) => void,
    private recentStore: RecentImages = recent,
    private getHint: () => string = () => "click or /b-image to open",
    private loadOptions: Pick<LoadImageOptions, "createWorker"> = {},
  ) {}

  private setWanted(next: string[]): void {
    this.wanted = next;
    for (const file of [...this.entries.keys()]) {
      if (!next.includes(file)) this.drop(file);
    }
    for (const file of next) {
      if (!this.entries.has(file)) this.load(file);
    }
  }

  private resolveText(text: string): void {
    const token = Symbol("resolve");
    this.resolveToken = token;
    const isCancelled = () =>
      this.disposed || this.resolveToken !== token || this.lastText !== text;
    void (async () => {
      let next: string[] = [];
      try {
        next = await extractImagePathsAsync(text, this.cwd, isCancelled);
      } catch {
        next = [];
      }
      if (isCancelled()) return;
      this.setWanted(next);
      this.tui.requestRender();
    })();
  }

  private load(file: string): void {
    const token = Symbol(file);
    const controller = new AbortController();
    this.entries.set(file, { status: "loading", token, controller });
    void (async () => {
      let entry: Entry = { status: "failed" };
      try {
        const loaded = await loadImage(file, {
          maxWidth: THUMB_MAX_DIM,
          maxHeight: THUMB_MAX_DIM,
          maxOutputBytes: THUMB_MAX_PNG_BYTES,
          signal: controller.signal,
          ...this.loadOptions,
        });
        if (loaded) {
          const kittyId =
            getCapabilities().images === "kitty"
              ? allocateImageId()
              : undefined;
          entry = {
            status: "ready",
            image: newImage(
              this.theme,
              loaded,
              file,
              kittyId,
              MAX_WIDTH_CELLS,
              MAX_HEIGHT_CELLS,
            ),
            mime: loaded.mime,
            meta: loaded.meta,
            kittyId,
          };
        }
      } catch {
        entry = { status: "failed" };
      }
      // Ignore a result for a widget that was disposed, or a path dropped and re-added meanwhile.
      const current = this.entries.get(file);
      if (
        this.disposed ||
        current?.status !== "loading" ||
        current.token !== token
      ) {
        if (entry.status === "ready") deleteKitty(this.tui, entry.kittyId);
        return;
      }
      this.entries.set(file, entry);
      this.tui.requestRender();
    })();
  }

  private drop(file: string): void {
    const entry = this.entries.get(file);
    this.entries.delete(file);
    if (entry?.status === "loading") entry.controller.abort();
    if (entry?.status === "ready") deleteKitty(this.tui, entry.kittyId);
  }

  invalidate(): void {
    for (const entry of this.entries.values()) {
      if (entry.status === "ready") entry.image.invalidate();
    }
  }

  handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    if (event.type !== "click" || event.button !== "left") return undefined;
    const block = this.blocks.find(
      (b) => event.y >= b.start && event.y < b.end,
    );
    if (!block) return undefined;
    this.open(block.file, block.index);
    return { handled: true };
  }

  render(width: number): string[] {
    this.blocks = [];
    if (this.disposed || popup.state === "open") return [];
    const text = this.getText();
    if (text !== this.lastText) {
      this.lastText = text;
      if (!text.trim()) {
        this.resolveToken = undefined;
        this.setWanted([]);
      } else {
        this.resolveText(text);
      }
    }

    // Nothing is drawn while an image loads or if it failed: no flicker, no noise.
    // The frame is a top and bottom rule only: image lines must stay untouched, because
    // pi-tui places Kitty images from the raw escape sequence at the start of the line.
    const isKitty = getCapabilities().images === "kitty";
    const lines: string[] = [];
    const displayed: string[] = [];
    for (const file of this.wanted) {
      const entry = this.entries.get(file);
      if (!entry || entry.status !== "ready") continue;
      if (isKitty && entry.mime !== "image/png") {
        // Capabilities switched to Kitty after a non-Kitty load: reload off-thread
        // as PNG rather than letting Pi's Image.render() run its sync transcoder.
        this.drop(file);
        this.load(file);
        continue;
      }
      const index = displayed.length;
      const title = `${imageLabel(file, index)} · ${entry.meta}`;
      const start = lines.length;
      lines.push(rule(this.theme, width, title, this.getHint()));
      lines.push(...entry.image.render(width));
      lines.push(rule(this.theme, width));
      this.blocks.push({ file, index, start, end: lines.length });
      displayed.push(file);
    }
    this.recentStore.set(displayed);
    return lines;
  }

  dispose(): void {
    this.disposed = true;
    this.resolveToken = undefined;
    for (const file of [...this.entries.keys()]) this.drop(file);
  }
}

const POPUP_MARGIN_COLS = 8;
const POPUP_CHROME_ROWS = 6;

/** Cell size of `dims` at its natural pixel size (up to 2x), fitted inside maxCols x maxRows. */
function popupImageSize(
  dims: ImageDimensions | null,
  maxCols: number,
  maxRows: number,
): { cols: number; rows: number } {
  const cell = getCellDimensions();
  const w = dims?.widthPx ?? 800;
  const h = dims?.heightPx ?? 600;
  const scale = Math.min(
    2,
    (maxCols * cell.widthPx) / w,
    (maxRows * cell.heightPx) / h,
  );
  return {
    cols: Math.max(
      1,
      Math.min(maxCols, Math.round((w * scale) / cell.widthPx)),
    ),
    rows: Math.max(
      1,
      Math.min(maxRows, Math.round((h * scale) / cell.heightPx)),
    ),
  };
}

/**
 * Centered popup with a bordered frame. Kitty images are placed from a raw escape sequence
 * on the first row, so every row is built as border + padding + (sequence) + fill + border:
 * the sequence has zero width and the fill keeps the right border in place.
 */
export class ViewerComponent implements Component {
  private image?: Image;
  private kittyId: number | undefined;
  private closed = false;
  private readonly safeTitle: string;
  private readonly safeFile: string;
  private readonly mime: string;
  readonly width: number;

  constructor(
    private tui: TUI,
    private theme: Theme,
    title: string,
    file: string,
    private loaded: Loaded,
    private done: () => void,
  ) {
    this.safeTitle = sanitizeTerminalText(title);
    this.safeFile = sanitizeTerminalText(file);
    this.mime = loaded.mime;
    const caps = getCapabilities().images;
    const maxCols = Math.max(10, tui.terminal.columns - POPUP_MARGIN_COLS - 4);
    const maxRows = Math.max(3, tui.terminal.rows - POPUP_CHROME_ROWS - 2);
    if (caps === "kitty" && loaded.mime === "image/png") {
      const size = popupImageSize(loaded.dims, maxCols, maxRows);
      this.kittyId = allocateImageId();
      // Image renders at min(width - 2, maxWidthCells): give it exactly size.cols + 2.
      this.image = newImage(
        theme,
        loaded,
        file,
        this.kittyId,
        size.cols,
        size.rows,
      );
      this.width = size.cols + 6;
    } else {
      this.width = Math.min(maxCols + 4, 60);
    }
  }

  handleInput(data: string): void {
    if (
      matchesKey(data, "escape") ||
      matchesKey(data, "enter") ||
      matchesKey(data, "space") ||
      data === "q"
    ) {
      this.done();
    }
  }

  handleMouse(event: TuiMouseEvent): TuiMouseEventResult | undefined {
    if (event.type === "click") {
      this.done();
      return { handled: true };
    }
    return undefined;
  }

  invalidate(): void {
    this.image?.invalidate();
  }

  render(width: number): string[] {
    const border = (s: string) => this.theme.fg("borderAccent", s);
    const inner = Math.max(1, width - 2);
    const row = (content: string) => {
      const pad = Math.max(0, inner - 1 - visibleWidth(content));
      return `${border("│")} ${content}${" ".repeat(pad)}${border("│")}`;
    };
    const titled = (left: string, right: string) => {
      const l = ` ${left} `;
      const r = ` ${right} `;
      const fill = Math.max(0, inner - visibleWidth(l) - visibleWidth(r) - 1);
      return truncateToWidth(
        `${border("╭─")}${this.theme.fg("accent", l)}${border("─".repeat(fill))}${this.theme.fg("dim", r)}${border("╮")}`,
        width,
      );
    };

    const isKitty = getCapabilities().images === "kitty";
    const body: string[] = [];
    if (this.image && !(isKitty && this.mime !== "image/png")) {
      body.push(...this.image.render(inner));
    } else if (isKitty && this.mime !== "image/png") {
      body.push(
        this.theme.fg(
          "muted",
          "Reopen /b-image to convert this image for Kitty graphics.",
        ),
        this.theme.fg("dim", this.safeFile),
      );
    } else {
      body.push(
        this.theme.fg(
          "muted",
          "Image preview needs a terminal with the Kitty graphics protocol.",
        ),
        this.theme.fg("dim", this.safeFile),
      );
    }
    return [
      titled(`${this.safeTitle} · ${this.loaded.meta}`, "Esc to close"),
      row(""),
      ...body.map((line) => row(line)),
      row(""),
      `${border("╰")}${border("─".repeat(Math.max(0, inner)))}${border("╯")}`,
    ].map((line) => (this.image ? line : truncateToWidth(line, width)));
  }

  dispose(): void {
    if (this.closed) return;
    this.closed = true;
    deleteKitty(this.tui, this.kittyId);
  }
}

async function openViewer(
  ctx: ExtensionContext,
  file: string,
  title: string,
): Promise<void> {
  // Reserve the slot before the async read so a double click cannot open two popups.
  const token = popup.acquire();
  if (!token) return;
  const controller = new AbortController();
  popup.onClose(token, () => controller.abort());
  let tuiRef: TUI | undefined;
  let viewer: ViewerComponent | undefined;
  try {
    const loaded = await loadImage(file, { signal: controller.signal });
    if (!loaded) {
      if (!controller.signal.aborted) {
        ctx.ui.notify(previewErrorMessage(file), "warning");
      }
      return;
    }
    // The session was replaced while the image loaded: do not open a popup in a stale one.
    if (!popup.open(token)) return;
    await ctx.ui.custom<void>(
      (tui, theme, _keybindings, done) => {
        tuiRef = tui;
        const created = new ViewerComponent(
          tui,
          theme,
          title,
          file,
          loaded,
          () => done(),
        );
        viewer = created;
        // On session shutdown: settle custom() and free the viewer's Kitty image.
        popup.onClose(token, () => {
          done();
          created.dispose();
        });
        return created;
      },
      {
        overlay: true,
        // The width depends on the image, so it is read from the component on each layout.
        overlayOptions: () => ({
          anchor: "center",
          width: viewer?.width ?? 40,
        }),
      },
    );
  } finally {
    controller.abort();
    viewer?.dispose();
    // Only the current owner releases the slot and re-renders; a stale operation does neither.
    if (popup.release(token)) {
      // Pi re-renders as soon as the overlay closes, while the thumbnail was still hidden.
      // Render again now that the state is cleared, and once more on the next tick in case
      // the overlay teardown renders last.
      tuiRef?.requestRender();
      setTimeout(() => tuiRef?.requestRender(), 0);
    }
  }
}

/** "" -> undefined (first image); a whole-string positive integer -> that number; else null. */
export function parseImageIndex(raw: string): number | undefined | null {
  if (raw === "") return undefined;
  if (!/^[1-9]\d{0,5}$/.test(raw)) return null;
  return Number(raw);
}

function openFor(ctx: ExtensionContext, file: string, index: number): void {
  void openViewer(ctx, file, imageLabel(file, index)).catch(() => {
    // The session may have been replaced while the image was loading.
  });
}

export default function (pi: ExtensionAPI) {
  let tuiActive = false;

  const isCommandOccupied = (): boolean => {
    try {
      return hasRegisteredCommand(pi.getCommands(), "b-image");
    } catch {
      return false;
    }
  };

  pi.on("session_shutdown", () => {
    tuiActive = false;
    popup.reset();
    cancelAllImageWorkers();
  });

  pi.on("session_start", (_event, ctx) => {
    tuiActive =
      process.env.PI_INPUT_IMAGE_PREVIEW !== "off" &&
      ctx.mode === "tui" &&
      ctx.hasUI;
    if (!tuiActive) return;

    ctx.ui.setWidget(
      WIDGET_KEY,
      (tui, theme) =>
        new PreviewWidget(
          tui,
          theme,
          () => ctx.ui.getEditorText(),
          ctx.cwd,
          (file, index) => openFor(ctx, file, index),
          recent,
          () =>
            isCommandOccupied() ? "click to open" : "click or /b-image to open",
        ),
      { placement: "aboveEditor" },
    );
  });

  // Defer /b-image dispatch to invocation time rather than registerCommand at session_start,
  // so extensions registering in a later session_start and prompt templates loaded later via
  // resources_discover (startup or reload) are never collided with or shadowed.
  pi.on("input", async (event, ctx) => {
    if (
      event.source !== "interactive" ||
      !tuiActive ||
      process.env.PI_INPUT_IMAGE_PREVIEW === "off" ||
      ctx.mode !== "tui" ||
      !ctx.hasUI
    ) {
      return { action: "continue" };
    }
    const match = /^\/b-image(?:\s+(.*))?$/.exec(event.text.trim());
    if (!match) return { action: "continue" };
    if (isCommandOccupied()) return { action: "continue" };
    const raw = (match[1] ?? "").trim();
    const n = parseImageIndex(raw);
    const file = n === null ? undefined : recent.get(n);
    if (!file) {
      ctx.ui.notify(imageNotFoundMessage(raw, recent.size), "info");
      return { action: "handled" };
    }
    await openViewer(ctx, file, imageLabel(file, (n ?? 1) - 1));
    return { action: "handled" };
  });
}
