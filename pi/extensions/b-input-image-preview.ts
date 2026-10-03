// Input image preview: show a framed thumbnail of image paths typed or pasted
// into the chat input, in a widget directly above the editor, before sending.
//
// Display-only: it never touches the editor, its text, or what is submitted.
// - Image paths in the editor (a Ctrl+V clipboard image, a dragged file, or a typed
//   path) get a thumbnail; the path text itself stays in the input as Pi inserts it.
// - Clicking a preview (fullscreen tuiMode routes mouse events) or running
//   `/image [n]` opens a centered popup (overlay) with the image at its natural
//   size (up to 2x, capped to the terminal); Esc, Enter, q, Space or a click on
//   the popup closes it. `/image` opens the n-th image of the most recent preview
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
import { constants } from "node:fs";
import { open } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type {
  ExtensionAPI,
  ExtensionContext,
  Theme,
} from "@earendil-works/pi-coding-agent";
import { convertToPng } from "@earendil-works/pi-coding-agent";
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

/** Short label for a preview: "Image n" for Pi's clipboard temp files, else the file name. */
export function imageLabel(file: string, index: number): string {
  return isClipboardImagePath(file)
    ? `Image ${index + 1}`
    : path.basename(file);
}

/**
 * The image paths of the most recent non-empty preview, for `/image [n]`: submitting the
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

// Tokens: "double quoted", 'single quoted', or bare with backslash escapes.
const TOKEN = /"([^"]+)"|'([^']+)'|((?:\\.|[^\s"'])+)/g;

export function extractImagePaths(text: string, cwd: string): string[] {
  const found: string[] = [];
  for (const match of text.matchAll(TOKEN)) {
    let raw = match[1] ?? match[2] ?? (match[3] ?? "").replace(/\\(.)/g, "$1");
    if (raw.startsWith("@")) raw = raw.slice(1);
    if (!IMAGE_EXT.test(raw)) continue;
    if (raw.startsWith("~/")) raw = path.join(os.homedir(), raw.slice(2));
    const resolved = path.resolve(cwd, raw);
    if (!found.includes(resolved)) found.push(resolved);
    if (found.length >= MAX_IMAGES) break;
  }
  return found;
}

interface Loaded {
  data: string;
  mime: string;
  dims: ImageDimensions | null;
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

/** Read an image file; null when it is missing, too large, or not a supported image. */
export async function loadImage(file: string): Promise<Loaded | null> {
  try {
    const buf = await readBounded(file);
    if (!buf) return null;
    let mime = sniffMime(buf);
    let data = buf.toString("base64");
    if (!mime) return null;
    if (getCapabilities().images === "kitty" && mime !== "image/png") {
      const converted = await convertToPng(data, mime);
      if (!converted) return null;
      data = converted.data;
      mime = converted.mimeType;
    }
    const dims = getImageDimensions(data, mime);
    const meta = [
      dims ? `${dims.widthPx}x${dims.heightPx}` : null,
      formatBytes(buf.length),
    ]
      .filter(Boolean)
      .join(" · ");
    return { data, mime, dims, meta };
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
      filename: path.basename(file),
      imageId: kittyId,
    },
    loaded.dims ?? undefined,
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
  | { status: "loading"; token: symbol }
  | { status: "ready"; image: Image; meta: string; kittyId?: number }
  | { status: "failed" };

interface Block {
  file: string;
  index: number;
  start: number;
  end: number;
}

class PreviewWidget implements Component {
  private entries = new Map<string, Entry>();
  private blocks: Block[] = [];
  private disposed = false;

  constructor(
    private tui: TUI,
    private theme: Theme,
    private getText: () => string,
    private cwd: string,
    private open: (file: string, index: number) => void,
  ) {}

  private load(file: string): void {
    const token = Symbol(file);
    this.entries.set(file, { status: "loading", token });
    void (async () => {
      let entry: Entry = { status: "failed" };
      try {
        const loaded = await loadImage(file);
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
    const wanted = extractImagePaths(this.getText(), this.cwd);

    for (const file of [...this.entries.keys()]) {
      if (!wanted.includes(file)) this.drop(file);
    }
    for (const file of wanted) {
      if (!this.entries.has(file)) this.load(file);
    }

    // Nothing is drawn while an image loads or if it failed: no flicker, no noise.
    // The frame is a top and bottom rule only: image lines must stay untouched, because
    // pi-tui places Kitty images from the raw escape sequence at the start of the line.
    const lines: string[] = [];
    wanted.forEach((file, index) => {
      const entry = this.entries.get(file);
      if (!entry || entry.status !== "ready") return;
      const title = `${imageLabel(file, index)} · ${entry.meta}`;
      const start = lines.length;
      lines.push(rule(this.theme, width, title, "click or /image to open"));
      lines.push(...entry.image.render(width));
      lines.push(rule(this.theme, width));
      this.blocks.push({ file, index, start, end: lines.length });
    });
    recent.set(wanted);
    return lines;
  }

  dispose(): void {
    this.disposed = true;
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
class ViewerComponent implements Component {
  private image?: Image;
  private kittyId: number | undefined;
  private closed = false;
  readonly width: number;

  constructor(
    private tui: TUI,
    private theme: Theme,
    private title: string,
    private file: string,
    private loaded: Loaded,
    private done: () => void,
  ) {
    const caps = getCapabilities().images;
    const maxCols = Math.max(10, tui.terminal.columns - POPUP_MARGIN_COLS - 4);
    const maxRows = Math.max(3, tui.terminal.rows - POPUP_CHROME_ROWS - 2);
    if (caps === "kitty") {
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

    const body: string[] = [];
    if (this.image) {
      body.push(...this.image.render(inner));
    } else {
      body.push(
        this.theme.fg(
          "muted",
          "Image preview needs a terminal with the Kitty graphics protocol.",
        ),
        this.theme.fg("dim", this.file),
      );
    }
    return [
      titled(`${this.title} · ${this.loaded.meta}`, "Esc to close"),
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
  let tuiRef: TUI | undefined;
  let viewer: ViewerComponent | undefined;
  try {
    const loaded = await loadImage(file);
    if (!loaded) {
      ctx.ui.notify(
        `Cannot preview ${path.basename(file)}: missing, too large, or not a supported image`,
        "warning",
      );
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
  let commandRegistered = false;

  pi.on("session_shutdown", () => {
    popup.reset();
  });

  pi.on("session_start", (_event, ctx) => {
    if (process.env.PI_INPUT_IMAGE_PREVIEW === "off") return;
    if (ctx.mode !== "tui" || !ctx.hasUI) return;

    // Registered here, not at load, so print/JSON/RPC runs and the opt-out never claim "/image".
    if (!commandRegistered) {
      commandRegistered = true;
      pi.registerCommand("image", {
        description:
          "Open an image from the latest preview full size: /image [n] (default: the first)",
        handler: async (args, cmdCtx) => {
          const raw = args.trim();
          const n = parseImageIndex(raw);
          const file = n === null ? undefined : recent.get(n);
          if (!file) {
            cmdCtx.ui.notify(
              recent.size === 0
                ? "No image preview yet: put an image path in the input first"
                : `No image ${raw || 1} in the latest preview (${recent.size} available)`,
              "info",
            );
            return;
          }
          await openViewer(cmdCtx, file, imageLabel(file, (n ?? 1) - 1));
        },
      });
    }

    ctx.ui.setWidget(
      WIDGET_KEY,
      (tui, theme) =>
        new PreviewWidget(
          tui,
          theme,
          () => ctx.ui.getEditorText(),
          ctx.cwd,
          (file, index) => openFor(ctx, file, index),
        ),
      { placement: "aboveEditor" },
    );
  });
}
