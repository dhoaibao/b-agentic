/**
 * Inline Markdown previews for Pi's TUI tool results.
 *
 * Preview rendering and tool execution are intentionally static: they do not
 * write preview files or change session messages. The explicit theme selector
 * may write only its namespaced global preference. In non-TUI modes the tool
 * returns a concise fallback.
 */
import { mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  copyToClipboard,
  getAgentDir,
  type ExtensionAPI,
  type ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
  Box,
  Markdown,
  Spacer,
  Text,
  truncateToWidth,
  type Component,
} from "@earendil-works/pi-tui";

type PreviewTheme = "moon" | "day";
type PreviewDetails = {
  markdown: string;
  title: string;
  theme: PreviewTheme;
};
type PreviewHistoryItem = {
  markdown: string;
  title: string;
};
type PreviewPalette = {
  pageBg: string;
  cardBg: string;
  deepest: string;
  highlight: string;
  text: string;
  muted: string;
  comment: string;
  border: string;
  accent: string;
  cyan: string;
  heading: string;
  codeBlock: string;
  inlineCode: string;
  link: string;
};
type FixedPalette = {
  pageBackground: string;
  cardBackground: string;
  deepestBackground: string;
  highlightBackground: string;
  text: string;
  muted: string;
  comment: string;
  border: string;
  header: string;
  cyan: string;
  heading: string;
  link: string;
  code: string;
  codeBlock: string;
};

const DEFAULT_TITLE = "Markdown preview";
const DEFAULT_PREVIEW_THEME: PreviewTheme = "moon";
const PREVIEW_RENDER_USAGE = "Usage: /preview-markdown:render <prompt>";
const PREVIEW_THEME_USAGE = "Usage: /preview-markdown:theme";
const PREVIEW_LIST_USAGE = "Usage: /preview-markdown:list";
const MAX_PREVIEW_HISTORY = 20;
const PREVIEW_THEME_CONFIG = "b-agentic/preview-theme.json";
const PREVIEW_THEME_LABELS: Record<PreviewTheme, string> = {
  moon: "Tokyo Night Moon",
  day: "Tokyo Night Day",
};
const PALETTE: PreviewPalette = {
  pageBg: "#1e2030",
  cardBg: "#222436",
  deepest: "#191b29",
  highlight: "#2f334d",
  text: "#c8d3f5",
  muted: "#828bb8",
  comment: "#636da6",
  border: "#3b4261",
  accent: "#82aaff",
  cyan: "#86e1fc",
  heading: "#ffc777",
  codeBlock: "#c3e88d",
  inlineCode: "#c099ff",
  link: "#65bcff",
} as const;
const DAY_PALETTE: PreviewPalette = {
  pageBg: "#d5d6db",
  cardBg: "#e1e2e7",
  deepest: "#c4c8da",
  highlight: "#dcdfe4",
  text: "#3760bf",
  muted: "#6172b0",
  comment: "#848cb5",
  border: "#8990b3",
  accent: "#2e7de9",
  cyan: "#007197",
  heading: "#8c6c3e",
  codeBlock: "#587539",
  inlineCode: "#9854f1",
  link: "#2e7de9",
} as const;
const ANSI_RESET = "\u001b[0m";
const ANSI_FOREGROUND_RESET = "\u001b[39m";

function truecolor(mode: "38" | "48", hex: string): string {
  const value = Number.parseInt(hex.slice(1), 16);
  const red = (value >> 16) & 0xff;
  const green = (value >> 8) & 0xff;
  const blue = value & 0xff;
  return `\u001b[${mode};2;${red};${green};${blue}m`;
}

function fixedPalette(palette: PreviewPalette): FixedPalette {
  return {
    pageBackground: truecolor("48", palette.pageBg),
    cardBackground: truecolor("48", palette.cardBg),
    deepestBackground: truecolor("48", palette.deepest),
    highlightBackground: truecolor("48", palette.highlight),
    text: truecolor("38", palette.text),
    muted: truecolor("38", palette.muted),
    comment: truecolor("38", palette.comment),
    border: truecolor("38", palette.border),
    header: truecolor("38", palette.accent),
    cyan: truecolor("38", palette.cyan),
    heading: truecolor("38", palette.heading),
    link: truecolor("38", palette.link),
    code: truecolor("38", palette.inlineCode),
    codeBlock: truecolor("38", palette.codeBlock),
  };
}

// Keep the reviewed Moon names and values stable for the default dark preview.
const FIXED_PAGE_BACKGROUND = truecolor("48", PALETTE.pageBg);
const FIXED_CARD_BACKGROUND = truecolor("48", PALETTE.cardBg);
const FIXED_DEEPEST_BACKGROUND = truecolor("48", PALETTE.deepest);
const FIXED_HIGHLIGHT_BACKGROUND = truecolor("48", PALETTE.highlight);
const FIXED_BORDER = truecolor("38", PALETTE.border);
const FIXED_HEADER = truecolor("38", PALETTE.accent);
const FIXED_TEXT = truecolor("38", PALETTE.text);
const FIXED_MUTED = truecolor("38", PALETTE.muted);
const FIXED_COMMENT = truecolor("38", PALETTE.comment);
const FIXED_CYAN = truecolor("38", PALETTE.cyan);
const FIXED_HEADING = truecolor("38", PALETTE.heading);
const FIXED_LINK = truecolor("38", PALETTE.link);
const FIXED_CODE = truecolor("38", PALETTE.inlineCode);
const FIXED_CODE_BLOCK = truecolor("38", PALETTE.codeBlock);
const MOON_FIXED_PALETTE: FixedPalette = {
  pageBackground: FIXED_PAGE_BACKGROUND,
  cardBackground: FIXED_CARD_BACKGROUND,
  deepestBackground: FIXED_DEEPEST_BACKGROUND,
  highlightBackground: FIXED_HIGHLIGHT_BACKGROUND,
  text: FIXED_TEXT,
  muted: FIXED_MUTED,
  comment: FIXED_COMMENT,
  border: FIXED_BORDER,
  header: FIXED_HEADER,
  cyan: FIXED_CYAN,
  heading: FIXED_HEADING,
  link: FIXED_LINK,
  code: FIXED_CODE,
  codeBlock: FIXED_CODE_BLOCK,
};
const DAY_FIXED_PALETTE = fixedPalette(DAY_PALETTE);
let lastPreviewMarkdown: string | undefined;
let currentPreviewTheme: PreviewTheme = DEFAULT_PREVIEW_THEME;
let currentPreviewThemeLoaded = false;
let currentPreviewThemeLoad: Promise<PreviewTheme> | undefined;
const previewRowInvalidators = new Map<string, () => void>();

function isPreviewTheme(value: unknown): value is PreviewTheme {
  return value === "moon" || value === "day";
}

function getPreviewThemePath(): string {
  return join(getAgentDir(), PREVIEW_THEME_CONFIG);
}

async function loadPreviewTheme(): Promise<PreviewTheme> {
  try {
    const parsed = JSON.parse(
      await readFile(getPreviewThemePath(), "utf8"),
    ) as { theme?: unknown };
    return isPreviewTheme(parsed?.theme) ? parsed.theme : DEFAULT_PREVIEW_THEME;
  } catch {
    return DEFAULT_PREVIEW_THEME;
  }
}

async function persistPreviewTheme(theme: PreviewTheme): Promise<boolean> {
  const path = getPreviewThemePath();
  const temporaryPath = `${path}.tmp-${process.pid}-${Date.now()}`;
  try {
    await mkdir(join(getAgentDir(), "b-agentic"), { recursive: true });
    await writeFile(temporaryPath, `${JSON.stringify({ theme }, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    await rename(temporaryPath, path);
    return true;
  } catch {
    await unlink(temporaryPath).catch(() => undefined);
    return false;
  }
}

function clearPreviewRowInvalidators(): void {
  previewRowInvalidators.clear();
}

function invalidatePreviewRows(): void {
  for (const [toolCallId, invalidate] of previewRowInvalidators) {
    try {
      invalidate();
    } catch {
      previewRowInvalidators.delete(toolCallId);
    }
  }
}

function rememberPreviewRowInvalidator(context: {
  toolCallId?: string;
  invalidate?: () => void;
}): void {
  if (!context.toolCallId || typeof context.invalidate !== "function") return;
  previewRowInvalidators.set(context.toolCallId, context.invalidate);
}

function setCurrentPreviewTheme(
  theme: PreviewTheme,
  invalidateRows: boolean,
): void {
  const changed = currentPreviewTheme !== theme;
  currentPreviewTheme = theme;
  currentPreviewThemeLoaded = true;
  if (changed && invalidateRows) invalidatePreviewRows();
}

function loadCurrentPreviewTheme(): Promise<PreviewTheme> {
  if (currentPreviewThemeLoaded) return Promise.resolve(currentPreviewTheme);
  currentPreviewThemeLoad ??= loadPreviewTheme().then((theme) => {
    currentPreviewThemeLoad = undefined;
    setCurrentPreviewTheme(theme, true);
    return theme;
  });
  return currentPreviewThemeLoad;
}

function fixedColor(color: string, text: string): string {
  return `${color}${text}${ANSI_FOREGROUND_RESET}`;
}

function fixedCodeSurface(
  background: string,
  foreground: string,
  text: string,
  cardBackground: string,
): string {
  return `${background}${foreground}${text}${ANSI_RESET}${cardBackground}`;
}

function fixedInlineCode(text: string, colors: FixedPalette): string {
  return fixedCodeSurface(
    colors.highlightBackground,
    colors.code,
    text,
    colors.cardBackground,
  );
}

function fixedCodeBlock(text: string, colors: FixedPalette): string {
  return fixedCodeSurface(
    colors.deepestBackground,
    colors.codeBlock,
    text,
    colors.cardBackground,
  );
}

function fixedCodeBlockBorder(text: string, colors: FixedPalette): string {
  return fixedCodeSurface(
    colors.deepestBackground,
    colors.comment,
    text,
    colors.cardBackground,
  );
}

function markdownTheme(colors: FixedPalette) {
  return {
    heading: (text: string) => fixedColor(colors.heading, text),
    link: (text: string) => fixedColor(colors.link, text),
    linkUrl: (text: string) => fixedColor(colors.comment, text),
    code: (text: string) => fixedInlineCode(text, colors),
    codeBlock: (text: string) => fixedCodeBlock(text, colors),
    codeBlockBorder: (text: string) => fixedCodeBlockBorder(text, colors),
    quote: (text: string) => fixedColor(colors.comment, text),
    quoteBorder: (text: string) => fixedColor(colors.comment, text),
    hr: (text: string) => fixedColor(colors.comment, text),
    listBullet: (text: string) => fixedColor(colors.cyan, text),
    bold: (text: string) => fixedColor(colors.text, text),
    italic: (text: string) => fixedColor(colors.text, text),
    strikethrough: (text: string) => fixedColor(colors.muted, text),
    underline: (text: string) => fixedColor(colors.header, text),
  };
}

const FIXED_MARKDOWN_THEME = markdownTheme(MOON_FIXED_PALETTE);

function colorsForTheme(theme: PreviewTheme): FixedPalette {
  return theme === "day" ? DAY_FIXED_PALETTE : MOON_FIXED_PALETTE;
}

class PreviewCard implements Component {
  private readonly body: Box;
  private readonly colors: FixedPalette;

  constructor(body: Box, colors: FixedPalette) {
    this.body = body;
    this.colors = colors;
  }

  render(width: number): string[] {
    if (width < 3) return this.body.render(width);

    const innerWidth = width - 2;
    const bodyLines = this.body
      .render(innerWidth)
      .map((line) => truncateToWidth(line, innerWidth, "", true));
    const pageLine = (line: string) =>
      `${this.colors.pageBackground}${line}${ANSI_RESET}`;
    const border = (left: string, right: string) =>
      pageLine(
        fixedColor(
          this.colors.border,
          `${left}${"─".repeat(innerWidth)}${right}`,
        ),
      );
    const framed = bodyLines.map(
      (line) =>
        `${this.colors.pageBackground}${fixedColor(this.colors.border, "│")}${line}${this.colors.pageBackground}${fixedColor(this.colors.border, "│")}${ANSI_RESET}`,
    );
    return [border("╭", "╮"), ...framed, border("╰", "╯")];
  }

  invalidate(): void {
    this.body.invalidate();
  }
}

function fallbackResult(mode: ExtensionContext["mode"]): {
  content: [{ type: "text"; text: string }];
  details: { interactive: false; mode: ExtensionContext["mode"] };
} {
  return {
    content: [
      {
        type: "text",
        text: "Markdown preview is only available in Pi TUI mode.",
      },
    ],
    details: { interactive: false, mode },
  };
}

async function selectPreviewTheme(ctx: ExtensionContext): Promise<void> {
  if (!ctx.hasUI) {
    ctx.ui.notify(
      "Preview theme selection is only available in Pi TUI mode",
      "warning",
    );
    return;
  }

  const current = await loadCurrentPreviewTheme();
  const options = (Object.keys(PREVIEW_THEME_LABELS) as PreviewTheme[]).map(
    (theme) =>
      `${PREVIEW_THEME_LABELS[theme]}${theme === current ? " (current)" : ""}`,
  );
  const selection = await ctx.ui.select("Select preview theme", options);
  if (selection === undefined) return;

  const theme = selection.startsWith(PREVIEW_THEME_LABELS.day)
    ? "day"
    : selection.startsWith(PREVIEW_THEME_LABELS.moon)
      ? "moon"
      : undefined;
  if (!theme) {
    ctx.ui.notify(
      "Unknown preview theme selection; keeping the current theme",
      "error",
    );
    return;
  }
  if (!(await persistPreviewTheme(theme))) {
    ctx.ui.notify(
      "Failed to save preview theme; keeping the current theme",
      "error",
    );
    return;
  }
  setCurrentPreviewTheme(theme, true);
  ctx.ui.notify(`Preview theme set to ${PREVIEW_THEME_LABELS[theme]}`, "info");
}

function getPreviewHistory(
  ctx: Pick<ExtensionContext, "sessionManager">,
): PreviewHistoryItem[] {
  const previews: PreviewHistoryItem[] = [];
  for (const entry of ctx.sessionManager.getBranch()) {
    if (
      entry.type !== "message" ||
      entry.message.role !== "toolResult" ||
      entry.message.toolName !== "preview_markdown" ||
      entry.message.isError === true
    )
      continue;
    const details = entry.message.details as
      Partial<PreviewDetails> | undefined;
    if (!details || typeof details.markdown !== "string") continue;
    previews.push({
      markdown: details.markdown,
      title:
        typeof details.title === "string" && details.title.trim()
          ? details.title
          : DEFAULT_TITLE,
    });
  }
  return previews.slice(-MAX_PREVIEW_HISTORY);
}

async function copyPreviewSource(
  ctx: ExtensionContext,
  preview: PreviewHistoryItem,
  copy: (markdown: string) => Promise<void> = copyToClipboard,
): Promise<void> {
  try {
    await copy(preview.markdown);
    ctx.ui.notify("Markdown preview source copied to clipboard", "info");
  } catch {
    ctx.ui.notify(
      "Failed to copy Markdown preview source to clipboard",
      "error",
    );
  }
}

async function listPreviewSources(
  ctx: ExtensionContext,
  copy: (markdown: string) => Promise<void> = copyToClipboard,
): Promise<void> {
  if (!ctx.hasUI) {
    ctx.ui.notify("Preview list is only available in Pi TUI mode", "warning");
    return;
  }

  const previews = getPreviewHistory(ctx);
  if (previews.length === 0) {
    ctx.ui.notify("No Markdown previews found on this branch", "warning");
    return;
  }

  const options = previews.map(
    (preview, index) => `${index + 1}. ${preview.title}`,
  );
  const selection = await ctx.ui.select("Select Markdown preview", options);
  if (selection === undefined) return;

  const index = options.indexOf(selection);
  if (index < 0) {
    ctx.ui.notify("Failed to select Markdown preview", "error");
    return;
  }
  await copyPreviewSource(ctx, previews[index], copy);
}

function buildPreviewRenderPrompt(prompt: string): string {
  return [
    "Render a Markdown response for the request below in one response.",
    "For your final Markdown response, you must invoke the preview_markdown tool exactly once with the complete original Markdown source. Do not write a file or send a separate prose response after the tool call.",
    "Request:",
    prompt,
  ].join("\n\n");
}

async function copyLatestPreviewSource(
  ctx: ExtensionContext,
  copy: (markdown: string) => Promise<void> = copyToClipboard,
): Promise<void> {
  if (lastPreviewMarkdown === undefined) {
    ctx.ui.notify("No Markdown preview source is available to copy", "warning");
    return;
  }

  try {
    await copy(lastPreviewMarkdown);
    ctx.ui.notify("Latest Markdown preview source copied to clipboard", "info");
  } catch {
    ctx.ui.notify(
      "Failed to copy latest Markdown preview source to clipboard",
      "error",
    );
  }
}

export default function bAgenticPreviewMarkdown(pi: ExtensionAPI): void {
  pi.on("session_shutdown", clearPreviewRowInvalidators);

  pi.registerShortcut("ctrl+shift+m", {
    description: "Copy the latest Markdown preview source",
    handler: (ctx) => copyLatestPreviewSource(ctx),
  });

  pi.registerCommand("preview-markdown:render", {
    description: "Render a one-request Markdown preview",
    handler: async (args, ctx) => {
      const prompt = args.trim();
      if (!prompt) {
        ctx.ui.notify(PREVIEW_RENDER_USAGE, "error");
        return;
      }
      pi.sendUserMessage(buildPreviewRenderPrompt(prompt), {
        deliverAs: "followUp",
      });
    },
  });

  pi.registerCommand("preview-markdown:theme", {
    description: "Select the global Tokyo Night preview theme",
    handler: async (args, ctx) => {
      if (args.trim()) {
        ctx.ui.notify(PREVIEW_THEME_USAGE, "error");
        return;
      }
      await selectPreviewTheme(ctx);
    },
  });

  pi.registerCommand("preview-markdown:list", {
    description: "List Markdown previews on the active branch",
    handler: async (args, ctx) => {
      if (args.trim()) {
        ctx.ui.notify(PREVIEW_LIST_USAGE, "error");
        return;
      }
      await listPreviewSources(ctx);
    },
  });

  pi.registerTool({
    name: "preview_markdown",
    label: "Preview Markdown",
    description: "Render Markdown inline in the Pi TUI without writing a file.",
    promptSnippet:
      "Render Markdown inline in the Pi TUI without creating a file",
    promptGuidelines: [
      "Use preview_markdown when the user asks to preview Markdown in Pi; pass the original Markdown source, not rendered text or an image.",
      "Use preview_markdown for an inline TUI tool result; copy the original source afterward with ctrl+shift+m; it does not write files or mutate session messages.",
    ],
    parameters: {
      type: "object",
      properties: {
        markdown: {
          type: "string",
          description: "The original Markdown source to preview.",
        },
        title: {
          type: "string",
          description: "Optional title shown above the preview.",
        },
      },
      required: ["markdown"],
      additionalProperties: false,
    } as const,
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const title = params.title?.trim() || DEFAULT_TITLE;
      if (ctx.mode !== "tui") return fallbackResult(ctx.mode);

      const theme = await loadCurrentPreviewTheme();
      const result = {
        content: [
          { type: "text" as const, text: "Markdown preview rendered inline." },
        ],
        details: {
          markdown: params.markdown,
          title,
          theme,
        } satisfies PreviewDetails,
      };
      lastPreviewMarkdown = params.markdown;
      return result;
    },
    renderResult(result, _options, _theme, context) {
      const details = result.details as PreviewDetails | undefined;
      if (!details || typeof details.markdown !== "string") {
        const text = result.content[0];
        return new Text(text?.type === "text" ? text.text : "", 0, 0);
      }

      rememberPreviewRowInvalidator(context);
      void loadCurrentPreviewTheme();
      const theme = currentPreviewTheme;
      const colors = colorsForTheme(theme);
      const body = new Box(
        1,
        1,
        (line) => `${colors.cardBackground}${line}${ANSI_RESET}`,
      );
      body.addChild(
        new Markdown(
          details.markdown,
          0,
          0,
          theme === DEFAULT_PREVIEW_THEME
            ? FIXED_MARKDOWN_THEME
            : markdownTheme(colors),
          {
            color: (text: string) => fixedColor(colors.text, text),
          },
          {
            preserveOrderedListMarkers: true,
          },
        ),
      );
      body.addChild(new Spacer(1));
      body.addChild(
        new Text(fixedColor(colors.comment, "Ctrl+Shift+M  Copy source"), 0, 0),
      );
      return new PreviewCard(body, colors);
    },
  });
}

export const __test__ = {
  DEFAULT_TITLE,
  DEFAULT_PREVIEW_THEME,
  PREVIEW_THEME_CONFIG,
  PREVIEW_RENDER_USAGE,
  PREVIEW_THEME_USAGE,
  PREVIEW_LIST_USAGE,
  MAX_PREVIEW_HISTORY,
  buildPreviewRenderPrompt,
  copyLatestPreviewSource,
  copyPreviewSource,
  getPreviewHistory,
  listPreviewSources,
  fallbackResult,
  isPreviewTheme,
  loadPreviewTheme,
  loadCurrentPreviewTheme,
  persistPreviewTheme,
};
