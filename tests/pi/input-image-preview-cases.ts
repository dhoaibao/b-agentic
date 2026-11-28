// Test-only extension for tests/pi/input-image-preview-probe.sh. At session start it exercises
// the pure parts of pi/extensions/b-input-image-preview/index.ts (path extraction, clipboard-path
// labels, the recent-preview list behind /b-image, popup-slot ownership, bounded file read) and
// writes one JSON result per case to $PROBE_OUT. Rendering, the popup, and mouse input need a
// terminal and are not covered.
import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { Worker } from "node:worker_threads";
import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";
import {
  DefaultResourceLoader,
  ExtensionRunner,
  createEventBus,
  createExtensionRuntime,
  discoverAndLoadExtensions,
  getPackageDir,
} from "@earendil-works/pi-coding-agent";
import {
  Image as TuiImage,
  getCapabilities,
  getImageDimensions,
  setCapabilities,
  setImageTranscoder,
  type TUI,
} from "@earendil-works/pi-tui";
import {
  PopupSlot,
  PreviewWidget,
  RecentImages,
  ViewerComponent,
  cancelAllImageWorkers,
  extractImagePaths,
  extractImagePathsAsync,
  hasRegisteredCommand,
  imageLabel,
  imageNotFoundMessage,
  isClipboardImagePath,
  loadImage,
  parseImageIndex,
  previewErrorMessage,
  sanitizeTerminalText,
} from "../../pi/extensions/b-input-image-preview/index.ts";

const results: Record<string, unknown> = {};
const check = (name: string, got: unknown, want: unknown) => {
  results[name] =
    JSON.stringify(got) === JSON.stringify(want) ? "ok" : { got, want };
};

const PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==",
  "base64",
);

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async () => {
    const out = process.env.PROBE_OUT;
    if (!out) return;
    const work = process.env.PROBE_WORK ?? os.tmpdir();
    const uuid = (n: string) =>
      `pi-clipboard-${n.repeat(8)}-1111-4111-8111-111111111111.png`;
    const clip = (n: string) => path.join(os.tmpdir(), uuid(n));
    const a = clip("a");
    const b = clip("b");

    // Clipboard temp names are labelled by position; every other path by its file name.
    check("clipboard path", isClipboardImagePath(a), true);
    check("not in tmpdir", isClipboardImagePath(`/home/x/${uuid("a")}`), false);
    check(
      "not clipboard name",
      isClipboardImagePath(path.join(os.tmpdir(), "shot.png")),
      false,
    );
    check("newline is plain text", isClipboardImagePath(`${a}\n`), false);
    check("leading space is plain text", isClipboardImagePath(` ${a}`), false);
    check(
      "label clipboard",
      [imageLabel(a, 0), imageLabel(b, 1)],
      ["Image 1", "Image 2"],
    );
    check(
      "label other",
      imageLabel("/shots/Screen Shot.png", 0),
      "Screen Shot.png",
    );

    // Path extraction.
    const cwd = "/work/proj";
    check("extract plain", extractImagePaths("hello", cwd), []);
    check(
      "extract ~ relative at",
      extractImagePaths("~/a.PNG ./b.webp @c/d.gif", cwd),
      [
        path.join(os.homedir(), "a.PNG"),
        "/work/proj/b.webp",
        "/work/proj/c/d.gif",
      ],
    );
    check(
      "extract quoted escaped",
      extractImagePaths('"/t/with space/x.png" /t/y\\ z.jpg', cwd),
      ["/t/with space/x.png", "/t/y z.jpg"],
    );
    check(
      "extract limits",
      extractImagePaths("/a/1.png /a/2.png /a/3.png /a/4.png /a/5.png", cwd)
        .length,
      4,
    );
    check("extract dedupes", extractImagePaths("/a/1.png /a/1.png", cwd), [
      "/a/1.png",
    ]);
    check(
      "extract ignores non-images",
      extractImagePaths("notes.txt image.pngx a.png,", cwd),
      [],
    );
    check(
      "extract unquoted spaced clipboard path",
      extractImagePaths("/tmp/Screen Shot.png", cwd),
      ["/tmp/Screen Shot.png"],
    );
    check(
      "extract multiple newline-separated spaced paths",
      extractImagePaths("/tmp/Screen Shot.png\n/tmp/Second Shot.jpg", cwd),
      ["/tmp/Screen Shot.png", "/tmp/Second Shot.jpg"],
    );
    check(
      "extract spaced clipboard path with cursor spacing",
      extractImagePaths("check /tmp/Screen Shot.png look", cwd),
      ["/tmp/Screen Shot.png"],
    );
    check(
      "extract relative spaced paths",
      extractImagePaths(
        "~/My Shots/a 1.png\n./sub dir/b 2.webp\n../up dir/c 3.gif",
        cwd,
      ),
      [
        path.join(os.homedir(), "My Shots/a 1.png"),
        "/work/proj/sub dir/b 2.webp",
        "/work/proj/../up dir/c 3.gif",
      ],
    );
    check(
      "extract avoids basename collision on spaced path",
      extractImagePaths("/tmp/sub/Screen Shot.png", cwd),
      ["/tmp/sub/Screen Shot.png"],
    );
    check(
      "extract ignores earlier non-image slash token",
      extractImagePaths("see /tmp/foo and /tmp/bar.png", cwd),
      ["/tmp/bar.png"],
    );
    check(
      "extract preserves apostrophe in spaced path",
      extractImagePaths("/tmp/Casey's Screen Shot.png", cwd),
      ["/tmp/Casey's Screen Shot.png"],
    );
    check(
      "extract preserves literal backslash in path",
      extractImagePaths("/tmp/back\\slash.png", cwd),
      ["/tmp/back\\slash.png"],
    );
    check(
      "extract spaced path with unrelated quotes on same line",
      extractImagePaths('"hello" /tmp/Screen Shot.png', cwd),
      ["/tmp/Screen Shot.png"],
    );
    check(
      "extract preserves input order across bare and anchored tokens",
      extractImagePaths("first.png /tmp/second.png", cwd),
      ["/work/proj/first.png", "/tmp/second.png"],
    );
    check(
      "extract respects MAX_IMAGES in input order across mixed paths",
      extractImagePaths("1.png 2.png 3.png 4.png /tmp/5.png", cwd),
      [
        "/work/proj/1.png",
        "/work/proj/2.png",
        "/work/proj/3.png",
        "/work/proj/4.png",
      ],
    );

    // Display sanitization: control characters and ANSI/OSC escapes never reach terminal output.
    // eslint-disable-next-line no-control-regex
    const hasControlChars = (s: string) =>
      /[\u0000-\u001f\u007f-\u009f]/.test(s);
    const evilName = "shot\x1b[31m\x1b]0;pwn\x07\r\n\x9b2J.png";
    check(
      "sanitize strips escapes and controls",
      sanitizeTerminalText(evilName),
      "shot.png",
    );
    check("label sanitized", imageLabel(`/tmp/${evilName}`, 0), "shot.png");
    check(
      "preview error sanitized",
      hasControlChars(previewErrorMessage(`/tmp/${evilName}`)),
      false,
    );
    check(
      "not-found sanitized",
      [
        hasControlChars(imageNotFoundMessage("\x1b[2J9\x07", 2)),
        imageNotFoundMessage("\x1b[2J9\x07", 2),
      ],
      [false, "No image 9 in the latest preview (2 available)"],
    );

    // /b-image reads the latest non-empty preview; an empty render keeps it (the command line
    // itself clears the input), and indexes are 1-based.
    const recent = new RecentImages();
    check("recent starts empty", [recent.size, recent.get()], [0, undefined]);
    recent.set([a, b]);
    check("recent default first", recent.get(), a);
    check(
      "recent nth",
      [recent.get(1), recent.get(2), recent.get(3), recent.get(0)],
      [a, b, undefined, undefined],
    );
    recent.set([]);
    check("empty render keeps recent", [recent.size, recent.get(2)], [2, b]);
    recent.set([b]);
    check(
      "newer preview replaces",
      [recent.size, recent.get(), recent.get(2)],
      [1, b, undefined],
    );

    // Popup slot: one at a time, and only the current owner may open or release it.
    const slot = new PopupSlot();
    const t1 = slot.acquire();
    check("slot acquired", typeof t1, "symbol");
    check("slot busy", slot.acquire(), undefined);
    slot.reset();
    check("reset idles", slot.state, "idle");
    const t2 = slot.acquire() as symbol;
    check("stale open refused", slot.open(t1 as symbol), false);
    check("stale release refused", slot.release(t1 as symbol), false);
    check("stale left new owner alone", slot.state, "loading");
    check("owner opens", slot.open(t2), true);
    check("owner releases", [slot.release(t2), slot.state], [true, "idle"]);
    check("double release refused", slot.release(t2), false);

    // Shutdown while a popup is open finishes it exactly once, and the stale owner is inert.
    const slot2 = new PopupSlot();
    const t3 = slot2.acquire() as symbol;
    slot2.open(t3);
    let closed = 0;
    slot2.onClose(t3, () => {
      closed += 1;
    });
    slot2.reset();
    slot2.reset();
    check(
      "shutdown closes open popup once",
      [closed, slot2.state],
      [1, "idle"],
    );
    check("stale release after shutdown", slot2.release(t3), false);
    const t4 = slot2.acquire() as symbol;
    slot2.open(t4);
    slot2.onClose(t3, () => {
      closed += 100;
    });
    slot2.reset();
    check("stale onClose ignored", closed, 1);
    const slot3 = new PopupSlot();
    const t5 = slot3.acquire() as symbol;
    slot3.open(t5);
    slot3.onClose(t5, () => {
      throw new Error("host gone");
    });
    let threw = false;
    try {
      slot3.reset();
    } catch {
      threw = true;
    }
    check("closer error swallowed", [threw, slot3.state], [false, "idle"]);

    // /b-image argument: whole-string positive integer only.
    check(
      "parse index",
      ["", "1", "12", "2.5", "2junk", "2 3", "0", "-1", "abc", "9999999"].map(
        parseImageIndex,
      ),
      [undefined, 1, 12, null, null, null, null, null, null, null],
    );

    // Bounded read: a file over the 20 MB cap is refused, a small PNG loads.
    mkdirSync(work, { recursive: true });
    const small = path.join(work, "small.png");
    const big = path.join(work, "big.png");
    const notImage = path.join(work, "fake.png");
    writeFileSync(small, PNG);
    writeFileSync(big, Buffer.concat([PNG, Buffer.alloc(21 * 1024 * 1024)]));
    writeFileSync(notImage, "this is text, not an image");
    const ok = await loadImage(small);
    check("load small", ok ? { mime: ok.mime, w: ok.dims?.widthPx } : null, {
      mime: "image/png",
      w: 1,
    });
    check("load oversized", await loadImage(big), null);
    check("load missing", await loadImage(path.join(work, "nope.png")), null);
    check("load by content not name", await loadImage(notImage), null);
    check("load directory", await loadImage(work), null);

    // A FIFO with no writer must be rejected without blocking, and a later valid load must still work.
    const fifo = path.join(work, "pipe.png");
    let fifoMade = true;
    try {
      execFileSync("mkfifo", [fifo]);
    } catch {
      fifoMade = false;
    }
    if (fifoMade) {
      const timedOut = Symbol("timeout");
      let timer: ReturnType<typeof setTimeout> | undefined;
      const raced = await Promise.race([
        loadImage(fifo),
        new Promise<symbol>((resolve) => {
          timer = setTimeout(() => resolve(timedOut), 3000);
        }),
      ]);
      if (timer) clearTimeout(timer);
      check(
        "load fifo without writer",
        raced === timedOut ? "timeout" : raced,
        null,
      );
      const again = await loadImage(small);
      check("load after fifo", again ? again.mime : null, "image/png");
    }

    // Rendered components: sanitize control characters and update recent only from ready thumbnails.
    const fakeTheme = {
      fg: (_color: string, s: string) => s,
    } as unknown as Theme;
    const fakeTui = {
      requestRender() {},
      terminal: { columns: 100, rows: 40, write() {} },
    } as unknown as TUI;

    const prevCaps = getCapabilities();
    setCapabilities({ images: null, trueColor: false, hyperlinks: false });
    try {
      const evilPath = path.join(work, "evil\x1b[31m\x07\rname.png");
      writeFileSync(evilPath, PNG);
      const evilLoaded = await loadImage(evilPath);
      if (evilLoaded) {
        const viewer = new ViewerComponent(
          fakeTui,
          fakeTheme,
          imageLabel(evilPath, 0),
          evilPath,
          evilLoaded,
          () => {},
        );
        const viewerLines = viewer.render(80);
        check(
          "viewer render has no control chars",
          viewerLines.some((line) => hasControlChars(line)),
          false,
        );
        const truncatedViewerLines = viewer.render(60);
        check(
          "truncated viewer render has no injected control chars",
          truncatedViewerLines.some((line) =>
            hasControlChars(line.replace(/\u001b\[0m/g, "")),
          ),
          false,
        );
        viewer.dispose();
      } else {
        check("viewer render has no control chars", "load failed", false);
      }

      const widgetEvilPath = path.join(work, "evil\x1b[31m\x07name.png");
      writeFileSync(widgetEvilPath, PNG);
      let editorText = `${notImage}\n${widgetEvilPath}`;
      const widgetRecent = new RecentImages();
      const widget = new PreviewWidget(
        fakeTui,
        fakeTheme,
        () => editorText,
        work,
        () => {},
        widgetRecent,
      );
      // Initial render kicks off async loads; nothing is ready yet so recent stays empty.
      const loadingLines = widget.render(80);
      check(
        "loading render draws nothing and leaves recent empty",
        [loadingLines.length, widgetRecent.size],
        [0, 0],
      );
      await new Promise((resolve) => setTimeout(resolve, 100));
      const readyLines = widget.render(80);
      check(
        "mixed render records only ready image",
        [readyLines.length > 0, widgetRecent.size, widgetRecent.get(1)],
        [true, 1, widgetEvilPath],
      );
      check(
        "widget render has no control chars",
        readyLines.some((line) => hasControlChars(line)),
        false,
      );
      // Switching to an invalid path or clearing the editor retains the last displayed image.
      editorText = notImage;
      widget.render(80);
      await new Promise((resolve) => setTimeout(resolve, 50));
      const failedLines = widget.render(80);
      check(
        "failed-only render retains last displayed",
        [failedLines.length, widgetRecent.size, widgetRecent.get(1)],
        [0, 1, widgetEvilPath],
      );
      editorText = "";
      const clearedLines = widget.render(80);
      check(
        "empty editor retains last displayed",
        [clearedLines.length, widgetRecent.size, widgetRecent.get(1)],
        [0, 1, widgetEvilPath],
      );
      widget.dispose();
    } finally {
      setCapabilities(prevCaps);
    }

    // Real-file lstat-backed native paths (R3-1): literal backslash-space, embedded ext,
    // embedded " /", explicitly escaped typed path, and mixed input at MAX_IMAGES.
    const nativeDir = path.join(work, "native");
    mkdirSync(nativeDir, { recursive: true });
    const keepSpace = path.join(nativeDir, "keep\\ space.png");
    const copyPng = path.join(nativeDir, "screenshot.png copy.png");
    const leadingSpaceSub = path.join(nativeDir, "two ");
    mkdirSync(leadingSpaceSub, { recursive: true });
    const leadingSpace = path.join(leadingSpaceSub, "leading-space.png");
    const escapedTarget = path.join(nativeDir, "escaped file.png");
    const fifthReal = path.join(nativeDir, "5.png");
    for (const f of [
      keepSpace,
      copyPng,
      leadingSpace,
      escapedTarget,
      fifthReal,
    ]) {
      writeFileSync(f, PNG);
    }
    check(
      "lstat preserves literal backslash-space",
      extractImagePaths(keepSpace, work),
      [keepSpace],
    );
    check(
      "lstat preserves embedded .png space",
      extractImagePaths(copyPng, work),
      [copyPng],
    );
    check(
      "lstat preserves embedded space-slash",
      extractImagePaths(leadingSpace, work),
      [leadingSpace],
    );
    check(
      "lstat preserves literal path after prose",
      extractImagePaths(`check ${keepSpace}`, work),
      [keepSpace],
    );
    check(
      "lstat resolves explicitly escaped typed path when target exists",
      extractImagePaths(path.join(nativeDir, "escaped\\ file.png"), work),
      [escapedTarget],
    );
    check(
      "lstat mixed real and bare paths keep order and 4-image cap",
      extractImagePaths(`1.png 2.png 3.png 4.png ${fifthReal}`, work),
      [
        path.join(work, "1.png"),
        path.join(work, "2.png"),
        path.join(work, "3.png"),
        path.join(work, "4.png"),
      ],
    );

    // R4-2 & R5-1: preserve ".." across symlink parents and never fall back to lexical normalization
    // when a literal target is missing even if a normalized decoy exists.
    const symRoot = path.join(work, "symroot");
    const symSub = path.join(symRoot, "sub");
    const symInner = path.join(symSub, "inner");
    mkdirSync(symInner, { recursive: true });
    const realThroughSym = path.join(symSub, "target.png");
    const decoyNormalized = path.join(symRoot, "target.png");
    const realLink = path.join(symRoot, "link");
    writeFileSync(realThroughSym, PNG);
    // Write a valid PNG decoy at the lexically normalized path so only preserving ".." avoids it.
    writeFileSync(decoyNormalized, PNG);
    symlinkSync(symInner, realLink);
    const symCandidateRel = "link/../target.png";
    const symCandidateAbs = `${symRoot}/link/../target.png`;
    const symExpected = `${symRoot}/link/../target.png`;
    check(
      "lstat preserves .. across symlink parent (relative and absolute)",
      [
        extractImagePaths(symCandidateRel, symRoot),
        extractImagePaths(symCandidateAbs, work),
        extractImagePaths(`"${symCandidateRel}"`, symRoot),
        await extractImagePathsAsync(symCandidateRel, symRoot),
      ],
      [[symExpected], [symExpected], [symExpected], [symExpected]],
    );
    const symLoaded = await loadImage(
      extractImagePaths(symCandidateRel, symRoot)[0],
    );
    check(
      "symlink-parent extracted path loads real image instead of normalized decoy",
      symLoaded?.mime ?? null,
      "image/png",
    );

    const missingLiteralRel = "missing_dir/../target.png";
    const missingLiteralAbs = `${symRoot}/missing_dir/../target.png`;
    check(
      "missing literal .. path is not lexically collapsed onto decoy",
      [
        extractImagePaths(missingLiteralRel, symRoot),
        extractImagePaths(missingLiteralAbs, work),
        extractImagePaths(`"${missingLiteralRel}"`, symRoot),
        extractImagePaths(`see ${missingLiteralAbs}`, work),
        await extractImagePathsAsync(missingLiteralAbs, work),
      ],
      [
        [missingLiteralAbs],
        [missingLiteralAbs],
        [missingLiteralAbs],
        [missingLiteralAbs],
        [missingLiteralAbs],
      ],
    );
    check(
      "missing literal .. path does not load normalized decoy",
      await loadImage(extractImagePaths(missingLiteralAbs, work)[0]),
      null,
    );

    // R4-1 & R5-2: bounded scan + event-loop heartbeat on 1 MB paste, immediate abort on cancel,
    // and off-thread bounded Kitty resize/PNG conversion on a 4K JPEG.
    const bigRepeated = `${"/tmp/a.png ".repeat(1200)}1.png 2.png 3.png 4.png`;
    const syncT0 = performance.now();
    const bigSync = extractImagePaths(bigRepeated, work);
    const syncMs = performance.now() - syncT0;
    const asyncT0 = performance.now();
    const bigAsync = await extractImagePathsAsync(bigRepeated, work);
    const asyncMs = performance.now() - asyncT0;
    check(
      "large repeated-token line stays bounded and keeps order/cap",
      [
        bigSync.length === 4 &&
          bigSync[0] === "/tmp/a.png" &&
          bigSync[3] === path.join(work, "3.png"),
        bigAsync.length === 4 &&
          bigAsync[0] === "/tmp/a.png" &&
          bigAsync[3] === path.join(work, "3.png"),
        syncMs < 250,
        asyncMs < 250,
      ],
      [true, true, true, true],
    );

    const oneMbProse = "plain prose without image paths on this line\n".repeat(
      24000,
    );
    let maxScanGap = 0;
    let lastTick = performance.now();
    const scanTimer = setInterval(() => {
      const now = performance.now();
      const gap = now - lastTick;
      if (gap > maxScanGap) maxScanGap = gap;
      lastTick = now;
    }, 10);
    const oneMbPaths = await extractImagePathsAsync(oneMbProse, work);
    clearInterval(scanTimer);
    let cancelAfterOne = false;
    setTimeout(() => {
      cancelAfterOne = true;
    }, 0);
    const cancelledResult = await extractImagePathsAsync(
      oneMbProse,
      work,
      () => cancelAfterOne,
    );
    check(
      "1 MB scan keeps event loop responsive and honors cancellation",
      [oneMbPaths.length === 0, maxScanGap < 200, cancelledResult.length === 0],
      [true, true, true],
    );

    let staleText = oneMbProse;
    const staleWidget = new PreviewWidget(
      fakeTui,
      fakeTheme,
      () => staleText,
      work,
      () => {},
      new RecentImages(),
    );
    const renderT0 = performance.now();
    const syncRenderOut = staleWidget.render(80);
    const renderMs = performance.now() - renderT0;
    // Immediately mutate editor text during 1 MB paste before async scan settles.
    staleText = small;
    staleWidget.render(80);
    let settledLines: string[] = [];
    for (let i = 0; i < 100; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 50));
      settledLines = staleWidget.render(80);
      if (settledLines.length > 0) break;
    }
    check(
      "widget render is fast off-thread and discards stale 1 MB async scan",
      [
        syncRenderOut.length === 0,
        renderMs < 50,
        settledLines.length > 0 &&
          (settledLines[0]?.includes("small.png") ?? false),
      ],
      [true, true, true],
    );
    staleWidget.dispose();

    // Kitty 4K JPEG conversion runs off the UI thread with bounded output dimensions and bytes.
    const pkgDir = getPackageDir();
    const photonPath = existsSync(
      path.join(pkgDir, "dist", "utils", "photon.js"),
    )
      ? path.join(pkgDir, "dist", "utils", "photon.js")
      : path.join(pkgDir, "src", "utils", "photon.ts");
    const photonMod = await import(pathToFileURL(photonPath).href);
    const photon = await photonMod.loadPhoton();
    if (photon) {
      const baseImg = photon.PhotonImage.new_from_byteslice(
        new Uint8Array(PNG),
      );
      const img4k = photon.resize(
        baseImg,
        3840,
        2160,
        photon.SamplingFilter.Nearest,
      );
      const jpeg4kPath = path.join(work, "fourk.jpg");
      writeFileSync(jpeg4kPath, Buffer.from(img4k.get_bytes_jpeg(70)));
      baseImg.free();
      img4k.free();

      const savedCaps = getCapabilities();
      setCapabilities({
        images: "kitty",
        trueColor: true,
        hyperlinks: false,
      });
      try {
        let maxKittyGap = 0;
        let lastKittyTick = performance.now();
        const kittyTimer = setInterval(() => {
          const now = performance.now();
          const gap = now - lastKittyTick;
          if (gap > maxKittyGap) maxKittyGap = gap;
          lastKittyTick = now;
        }, 10);
        const thumb4k = await loadImage(jpeg4kPath, {
          maxWidth: 640,
          maxHeight: 640,
          maxOutputBytes: 2 * 1024 * 1024,
        });
        const popup4k = await loadImage(jpeg4kPath);
        clearInterval(kittyTimer);
        const thumbOutDims = thumb4k
          ? getImageDimensions(thumb4k.data, thumb4k.mime)
          : null;
        const popupOutDims = popup4k
          ? getImageDimensions(popup4k.data, popup4k.mime)
          : null;
        check(
          "Kitty 4K JPEG loads off-thread with bounded dimensions and size",
          [
            thumb4k?.mime === "image/png" &&
              popup4k?.mime === "image/png" &&
              thumb4k.dims?.widthPx === 3840 &&
              popup4k.dims?.widthPx === 3840,
            (thumbOutDims?.widthPx ?? 9999) <= 640 &&
              (thumbOutDims?.heightPx ?? 9999) <= 640 &&
              (popupOutDims?.widthPx ?? 9999) <= 1600 &&
              (popupOutDims?.heightPx ?? 9999) <= 1600,
            (thumb4k ? Buffer.byteLength(thumb4k.data, "base64") : 9e9) <=
              2 * 1024 * 1024 &&
              (popup4k ? Buffer.byteLength(popup4k.data, "base64") : 9e9) <=
                8 * 1024 * 1024,
            maxKittyGap < 400,
          ],
          [true, true, true, true],
        );

        // R6-1: Kitty renderer receives post-resize renderDims (not 3840x2160) so crops stay inside bitmap,
        // and EXIF-rotated JPEG updates renderDims and popup aspect orientation.
        if (thumb4k) {
          const thumbImg = new TuiImage(
            thumb4k.data,
            thumb4k.mime,
            { fallbackColor: (s: string) => s },
            { maxWidthCells: 36, maxHeightCells: 2, imageId: 77 },
            thumb4k.renderDims ?? undefined,
          );
          const renderedThumb = thumbImg.render(80).join("\n");
          check(
            "R6-1: resized Kitty thumbnail passes post-resize renderDims and stays within 2 rows",
            [
              thumb4k.renderDims?.widthPx === thumbOutDims?.widthPx &&
                thumb4k.renderDims?.heightPx === thumbOutDims?.heightPx,
              renderedThumb.includes("\x1b_G") &&
                !renderedThumb.includes(`h=${thumb4k.dims?.heightPx}`),
            ],
            [true, true],
          );
        } else {
          check(
            "R6-1: resized Kitty thumbnail passes post-resize renderDims and stays within 2 rows",
            "load failed",
            true,
          );
        }

        // EXIF Orientation=6 (90 deg CW) on a 20x10 JPEG must produce 10x20 renderDims and portrait dims.
        const orientSrc = photon.PhotonImage.new_from_byteslice(
          new Uint8Array(PNG),
        );
        const orientRect = photon.resize(
          orientSrc,
          20,
          10,
          photon.SamplingFilter.Nearest,
        );
        const rawRectJpeg = Buffer.from(orientRect.get_bytes_jpeg(90));
        orientSrc.free();
        orientRect.free();
        const exifApp1 = Buffer.from([
          0xff, 0xe1, 0x00, 0x1e, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00, 0x4d,
          0x4d, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08, 0x00, 0x01, 0x01, 0x12,
          0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x06, 0x00, 0x00,
        ]);
        const rotatedJpeg = Buffer.concat([
          rawRectJpeg.subarray(0, 2),
          exifApp1,
          rawRectJpeg.subarray(2),
        ]);
        const rotatedPath = path.join(work, "rotated.jpg");
        writeFileSync(rotatedPath, rotatedJpeg);
        const rotatedLoaded = await loadImage(rotatedPath);
        check(
          "R6-1: EXIF-rotated JPEG updates renderDims and natural orientation",
          [rotatedLoaded?.renderDims, rotatedLoaded?.dims],
          [
            { widthPx: 10, heightPx: 20 },
            { widthPx: 10, heightPx: 20 },
          ],
        );

        // R6-3: forced worker failure fails closed (null) for both thumbnail and popup without sync fallback.
        const failingWorker = () => {
          throw new Error("forced worker failure");
        };
        const [thumbFail, popupFail] = await Promise.all([
          loadImage(jpeg4kPath, {
            maxWidth: 640,
            maxHeight: 640,
            maxOutputBytes: 2 * 1024 * 1024,
            createWorker: failingWorker,
          }),
          loadImage(jpeg4kPath, { createWorker: failingWorker }),
        ]);
        check(
          "R6-3: worker failure fails closed for both thumbnail and popup",
          [thumbFail, popupFail],
          [null, null],
        );
      } finally {
        setCapabilities(savedCaps);
      }
    }

    // R6-2: 64 KiB boundary must never cut .pngx into .png (whole-line, anchored, bare),
    // while a real whitespace delimiter right at 64 KiB still extracts the valid path.
    const decoyPng = path.join(work, "b-review-decoy.png");
    const realPng = path.join(work, "b-review-real.png");
    writeFileSync(decoyPng, PNG);
    writeFileSync(realPng, PNG);
    const wholePrefix = `${work}/${"w".repeat(65536 - work.length - 2 - "b-review-decoy.png".length)}/`;
    const cutWholeLine = `${wholePrefix}b-review-decoy.pngx`;
    const anchoredLine = `${"z ".repeat(32000)}${" ".repeat(65536 - 64000 - decoyPng.length)}${decoyPng}x`;
    const bareTok = "b-review-decoy.pngx";
    const bareLine = `${"z ".repeat(32000)}${" ".repeat(65536 - 64000 - "b-review-decoy.png".length)}${bareTok}`;
    const validAtBoundary = `${"z ".repeat(32000)}${" ".repeat(65536 - 64000 - realPng.length)}${realPng} after`;
    check(
      "R6-2: 64 KiB cap never turns .pngx into .png across whole-line, anchored, or bare",
      [
        extractImagePaths(cutWholeLine, work),
        extractImagePaths(anchoredLine, work),
        extractImagePaths(bareLine, work),
        await extractImagePathsAsync(cutWholeLine, work),
        await extractImagePathsAsync(anchoredLine, work),
        await extractImagePathsAsync(bareLine, work),
      ],
      [[], [], [], [], [], []],
    );
    check(
      "R6-2: 64 KiB cap extracts complete path when delimiter sits at boundary",
      [
        extractImagePaths(validAtBoundary, work),
        await extractImagePathsAsync(validAtBoundary, work),
      ],
      [[realPng], [realPng]],
    );

    // R7-3: when both shot.png and `shot.png copy.png` exist and 64 KiB lands at the
    // space after shot.png, never fabricate the shorter shot.png.
    const r7Shot = path.join(work, "r7-shot.png");
    const r7ShotCopy = path.join(work, "r7-shot.png copy.png");
    writeFileSync(r7Shot, PNG);
    writeFileSync(r7ShotCopy, PNG);
    const r7LinePrefix = "z ".repeat(32000);
    const r7Pad = " ".repeat(65536 - r7LinePrefix.length - r7Shot.length);
    const r7MultiLine = `${r7LinePrefix}\n${" ".repeat(65536 - r7LinePrefix.length - 1 - r7Shot.length)}${r7ShotCopy}`;
    const r7SingleLine = `${r7LinePrefix}${r7Pad}${r7ShotCopy}`;
    check(
      "R7-3: multi-line 64 KiB cutoff drops incomplete `shot.png copy.png` instead of picking `shot.png`",
      [
        extractImagePaths(r7MultiLine, work),
        await extractImagePathsAsync(r7MultiLine, work),
      ],
      [[], []],
    );
    check(
      "R7-3: single-line 64 KiB cutoff looks ahead for `shot.png copy.png` instead of picking `shot.png`",
      [
        extractImagePaths(r7SingleLine, work),
        await extractImagePathsAsync(r7SingleLine, work),
      ],
      [[r7ShotCopy], [r7ShotCopy]],
    );

    // R7-5: switching capabilities to Kitty after a non-Kitty JPEG load must never invoke
    // Pi's synchronous Image.render() transcoder on either PreviewWidget or ViewerComponent.
    if (photon) {
      const r7JpegPath = path.join(work, "r7-cap-switch.jpg");
      const s = photon.PhotonImage.new_from_byteslice(new Uint8Array(PNG));
      writeFileSync(r7JpegPath, Buffer.from(s.get_bytes_jpeg(80)));
      s.free();

      const savedCapsR7 = getCapabilities();
      let syncTranscoderCalls = 0;
      setImageTranscoder(() => {
        syncTranscoderCalls += 1;
        throw new Error("sync transcoder must not run");
      });
      try {
        setCapabilities({
          images: null,
          trueColor: false,
          hyperlinks: false,
        });
        const nonKittyLoaded = await loadImage(r7JpegPath);
        const capWidget = new PreviewWidget(
          fakeTui,
          fakeTheme,
          () => r7JpegPath,
          work,
          () => {},
          new RecentImages(),
        );
        capWidget.render(80);
        let preSwitchLines: string[] = [];
        for (let i = 0; i < 100; i += 1) {
          await new Promise((resolve) => setTimeout(resolve, 50));
          preSwitchLines = capWidget.render(80);
          if (preSwitchLines.length > 0) break;
        }
        // Now switch to Kitty before second render.
        setCapabilities({
          images: "kitty",
          trueColor: true,
          hyperlinks: false,
        });
        const postSwitchLines = capWidget.render(80);
        // Also test ViewerComponent constructed under iterm2 (creates Image with jpeg mime) then switched to Kitty.
        setCapabilities({
          images: "iterm2",
          trueColor: true,
          hyperlinks: false,
        });
        let viewerThrew = false;
        let viewerMsg = "";
        if (nonKittyLoaded) {
          const capViewer = new ViewerComponent(
            fakeTui,
            fakeTheme,
            "r7",
            r7JpegPath,
            nonKittyLoaded,
            () => {},
          );
          setCapabilities({
            images: "kitty",
            trueColor: true,
            hyperlinks: false,
          });
          try {
            viewerMsg = capViewer.render(80).join("\n");
          } catch {
            viewerThrew = true;
          }
          capViewer.dispose();
        }
        let reloadedLines: string[] = [];
        for (let i = 0; i < 200; i += 1) {
          await new Promise((resolve) => setTimeout(resolve, 50));
          reloadedLines = capWidget.render(80);
          if (reloadedLines.some((l) => l.includes("\x1b_G"))) break;
        }
        capWidget.dispose();
        check(
          "R7-5: capability switch to Kitty never invokes sync transcoder on widget or viewer",
          [
            syncTranscoderCalls,
            preSwitchLines.length > 0,
            postSwitchLines.length === 0,
            !viewerThrew && viewerMsg.includes("Reopen /b-image"),
            reloadedLines.some((l) => l.includes("\x1b_G")),
          ],
          [0, true, true, true, true],
        );
      } finally {
        setCapabilities(savedCapsR7);
        setImageTranscoder(undefined);
      }
    }

    // R7-2: DefaultResourceLoader (Pi's normal startup discovery) discovers the preview extension
    // by default, and respects root index.ts and .gitignore exclusions.
    const resAgent = path.join(work, "res-agent");
    const resExtPreview = path.join(
      resAgent,
      "extensions",
      "b-input-image-preview",
    );
    mkdirSync(resExtPreview, { recursive: true });
    writeFileSync(
      path.join(resExtPreview, "index.ts"),
      "export default function () {}\n",
    );
    const loaderNormal = new DefaultResourceLoader({
      cwd: work,
      agentDir: resAgent,
      noExtensions: false,
    });
    await loaderNormal.reload();
    const normalPaths = loaderNormal
      .getExtensions()
      .extensions.map((e) => e.path);

    const resAgentIgnored = path.join(work, "res-agent-ignored");
    const resExtIgnored = path.join(
      resAgentIgnored,
      "extensions",
      "b-input-image-preview",
    );
    mkdirSync(resExtIgnored, { recursive: true });
    writeFileSync(
      path.join(resExtIgnored, "index.ts"),
      "export default function () {}\n",
    );
    writeFileSync(
      path.join(resAgentIgnored, "extensions", ".gitignore"),
      "b-input-image-preview/\n",
    );
    const loaderIgnored = new DefaultResourceLoader({
      cwd: work,
      agentDir: resAgentIgnored,
      noExtensions: false,
    });
    await loaderIgnored.reload();
    const ignoredPaths = loaderIgnored
      .getExtensions()
      .extensions.map((e) => e.path);

    check(
      "R7-2: DefaultResourceLoader discovers preview normally and honors .gitignore exclusion",
      [
        normalPaths.includes(path.join(resExtPreview, "index.ts")),
        ignoredPaths.includes(path.join(resExtIgnored, "index.ts")),
      ],
      [true, false],
    );

    // R8-4: over-budget source dimensions are rejected before worker decode, and slow workers
    // respect the shared concurrency cap (<= 4) and terminate on editor replacement / dispose / shutdown.
    {
      const savedCapsR8 = getCapabilities();
      setCapabilities({ images: "kitty", trueColor: true, hyperlinks: false });
      try {
        // Build a synthetic PNG header claiming 10000x10000 (100 MP > 25 MP cap).
        const bombPng = Buffer.from(PNG);
        bombPng.writeUInt32BE(10000, 16);
        bombPng.writeUInt32BE(10000, 20);
        const bombPath = path.join(work, "bomb.png");
        writeFileSync(bombPath, bombPng);
        let bombWorkerCalls = 0;
        const bombResult = await loadImage(bombPath, {
          createWorker: () => {
            bombWorkerCalls += 1;
            throw new Error("should not spawn worker");
          },
        });
        check(
          "R8-4: over-budget 100MP PNG rejected before worker decode",
          [bombResult, bombWorkerCalls],
          [null, 0],
        );

        // Slow fake workers to verify <= 4 in-flight cap and immediate termination on drop/dispose/shutdown.
        if (photon) {
          const slowJpegs: string[] = [];
          const sImg = photon.PhotonImage.new_from_byteslice(
            new Uint8Array(PNG),
          );
          const sBytes = Buffer.from(sImg.get_bytes_jpeg(80));
          sImg.free();
          for (let i = 0; i < 8; i += 1) {
            const p = path.join(work, `slow-${i}.jpg`);
            writeFileSync(p, sBytes);
            slowJpegs.push(p);
          }
          let active = 0;
          let maxActive = 0;
          let spawned = 0;
          let terminated = 0;
          const slowWorkerFactory = () => {
            const ee = new EventEmitter() as unknown as Worker & EventEmitter;
            active += 1;
            spawned += 1;
            if (active > maxActive) maxActive = active;
            let done = false;
            const timer = setTimeout(() => {
              if (done) return;
              done = true;
              active -= 1;
              ee.emit("message", {
                ok: true,
                res: { data: PNG.toString("base64"), mimeType: "image/png" },
              });
            }, 5000);
            ee.terminate = async () => {
              if (!done) {
                done = true;
                clearTimeout(timer);
                active -= 1;
                terminated += 1;
              }
              return 0;
            };
            return ee;
          };

          // 8 concurrent loads must cap active workers at 4; aborting cancels queued and active ones.
          const acBatch = new AbortController();
          const batchPromises = slowJpegs.map((p) =>
            loadImage(p, {
              createWorker: slowWorkerFactory,
              signal: acBatch.signal,
            }),
          );
          await new Promise((resolve) => setTimeout(resolve, 40));
          const peakDuringBatch = maxActive;
          const activeDuringBatch = active;
          acBatch.abort();
          const batchOut = await Promise.all(batchPromises);

          // PreviewWidget swap + dispose + cancelAllImageWorkers cleans up every in-flight worker.
          let editorSlowText = slowJpegs.slice(0, 4).join("\n");
          const slowWidget = new PreviewWidget(
            fakeTui,
            fakeTheme,
            () => editorSlowText,
            work,
            () => {},
            new RecentImages(),
            undefined,
            { createWorker: slowWorkerFactory },
          );
          slowWidget.render(80);
          await new Promise((resolve) => setTimeout(resolve, 40));
          editorSlowText = slowJpegs.slice(4, 8).join("\n");
          slowWidget.render(80);
          await new Promise((resolve) => setTimeout(resolve, 40));
          slowWidget.dispose();
          cancelAllImageWorkers();
          await new Promise((resolve) => setTimeout(resolve, 20));
          check(
            "R8-4: shared worker cap <= 4 and obsolete/disposed workers terminate cleanly",
            [
              peakDuringBatch <= 4 && activeDuringBatch <= 4,
              maxActive <= 4,
              batchOut.every((r) => r === null),
              terminated >= 4 && spawned >= 8,
              active === 0,
            ],
            [true, true, true, true, true],
          );
        }
      } finally {
        cancelAllImageWorkers();
        setCapabilities(savedCapsR8);
      }
    }

    // R6-4 discovery check: Pi loads index.ts over index.js and package.json pi.extensions over index.ts.
    const discAgentDir = path.join(work, "disc-agent");
    const discExtDir = path.join(
      discAgentDir,
      "extensions",
      "b-input-image-preview",
    );
    mkdirSync(discExtDir, { recursive: true });
    writeFileSync(
      path.join(discExtDir, "index.js"),
      "export default function () {}\n",
    );
    writeFileSync(
      path.join(discExtDir, "index.ts"),
      "export default function () {}\n",
    );
    const discJsVsTs = await discoverAndLoadExtensions(
      [],
      work,
      discAgentDir,
      createEventBus(),
    );
    writeFileSync(
      path.join(discExtDir, "custom.ts"),
      "export default function () {}\n",
    );
    writeFileSync(
      path.join(discExtDir, "package.json"),
      JSON.stringify({ pi: { extensions: ["./custom.ts"] } }),
    );
    const discPkgVsTs = await discoverAndLoadExtensions(
      [],
      work,
      discAgentDir,
      createEventBus(),
    );
    check(
      "R6-4: Pi discovery precedence confirms index.ts shadows index.js and package.json shadows index.ts",
      [
        discJsVsTs.extensions.map((e) => path.basename(e.path)),
        discPkgVsTs.extensions.map((e) => path.basename(e.path)),
      ],
      [["index.ts"], ["custom.ts"]],
    );

    // R4-3: /b-image stays clear of /image and image.md, defers dispatch to invocation time,
    // and yields to late-discovered resources_discover prompt templates on startup and reload.
    check(
      "hasRegisteredCommand detects extension and prompt commands",
      [
        hasRegisteredCommand([{ name: "other", source: "prompt" }], "b-image"),
        hasRegisteredCommand(
          [{ name: "b-image", source: "prompt" }],
          "b-image",
        ),
        hasRegisteredCommand(
          [{ name: "b-image", source: "extension" }],
          "b-image",
        ),
        hasRegisteredCommand(
          [{ name: "b-image:1", source: "extension" }],
          "b-image",
        ),
      ],
      [false, true, true, true],
    );

    const previewExtPath = fileURLToPath(
      new URL(
        "../../pi/extensions/b-input-image-preview/index.ts",
        import.meta.url,
      ),
    );
    const existingImageTop = path.join(work, "existing-image-top.ts");
    writeFileSync(
      existingImageTop,
      'export default function (pi: { registerCommand: (name: string, opts: unknown) => void }) { pi.registerCommand("image", { description: "existing /image", handler: async () => {} }); }\n',
    );
    const existingImageSession = path.join(work, "existing-image-session.ts");
    writeFileSync(
      existingImageSession,
      'export default function (pi: { on: (e: string, h: () => void) => void; registerCommand: (name: string, opts: unknown) => void }) { pi.on("session_start", () => { pi.registerCommand("image", { description: "late /image", handler: async () => {} }); }); }\n',
    );
    const existingBImage = path.join(work, "existing-b-image.ts");
    writeFileSync(
      existingBImage,
      'export default function (pi: { on: (e: string, h: () => void) => void; registerCommand: (name: string, opts: unknown) => void }) { pi.on("session_start", () => { pi.registerCommand("b-image", { description: "late /b-image", handler: async () => {} }); }); }\n',
    );
    const latePromptExt = path.join(work, "late-prompt-discover.ts");
    writeFileSync(
      latePromptExt,
      'export default function (pi: { on: (e: string, h: (ev: { reason: string }) => unknown) => void }) { pi.on("resources_discover", () => ({ promptPaths: ["/tmp/b-image.md"] })); }\n',
    );
    const emptyAgentDir = path.join(work, "empty-agent");
    mkdirSync(emptyAgentDir, { recursive: true });

    const runCommandResolution = async (
      paths: string[],
      options: {
        mode?: "tui" | "json";
        preloadedPrompts?: string[];
        discoverLateTemplateOn?: "startup" | "reload";
        inputSource?: "interactive" | "extension";
      } = {},
    ) => {
      const eventBus = createEventBus();
      const loaded = await discoverAndLoadExtensions(
        paths,
        work,
        emptyAgentDir,
        eventBus,
      );
      const runtime = loaded.runtime ?? createExtensionRuntime();
      const runner = new ExtensionRunner(
        loaded.extensions,
        runtime,
        work,
        {} as never,
        {} as never,
      );
      const discoveredPrompts = [...(options.preloadedPrompts ?? [])];
      const runnerErrors: string[] = [];
      runner.onError((err) => runnerErrors.push(err.error));
      let capturedWidget: { render: (w: number) => string[] } | undefined;
      runner.setUIContext(
        {
          setWidget(
            _k: string,
            factory: (
              tui: unknown,
              theme: unknown,
            ) => { render: (w: number) => string[] },
          ) {
            if (typeof factory === "function") {
              capturedWidget = factory(fakeTui, fakeTheme);
            }
          },
          notify() {},
          getEditorText: () => small,
          async custom(
            factory: (
              tui: unknown,
              theme: unknown,
              keybindings: unknown,
              done: () => void,
            ) => { dispose?: () => void },
          ) {
            const comp = factory(fakeTui, fakeTheme, {}, () => {});
            comp?.dispose?.();
          },
        } as never,
        options.mode ?? "tui",
      );
      runner.bindCore(
        {
          getCommands: () => [
            ...runner.getRegisteredCommands().map((cmd) => ({
              name: cmd.invocationName,
              description: cmd.description,
              source: "extension" as const,
              sourceInfo: cmd.sourceInfo,
            })),
            ...discoveredPrompts.map((name) => ({
              name,
              description: "prompt template",
              source: "prompt" as const,
              sourceInfo: {} as never,
            })),
          ],
        } as never,
        {} as never,
      );
      await runner.emit({ type: "session_start", reason: "startup" });
      if (options.discoverLateTemplateOn) {
        const res = await runner.emitResourcesDiscover(
          work,
          options.discoverLateTemplateOn,
        );
        for (const p of res.promptPaths) {
          discoveredPrompts.push(path.basename(p.path, ".md"));
        }
      }
      if (capturedWidget) {
        capturedWidget.render(80);
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      const hintLine = capturedWidget?.render(80)[0] ?? "";
      const inputResult = await runner.emitInput(
        "/b-image 1",
        undefined,
        options.inputSource ?? "interactive",
      );
      const bImage = runner.getCommand("b-image");
      const bareImage = runner.getCommand("image");
      return {
        errors: loaded.errors.length + runnerErrors.length,
        inputAction: inputResult.action,
        hintAdvertisesBImage: hintLine.includes("/b-image"),
        bImagePath: bImage?.sourceInfo.path ?? null,
        bareImagePath: bareImage?.sourceInfo.path ?? null,
        bImageNames: runner
          .getRegisteredCommands()
          .filter((cmd) => cmd.name === "b-image")
          .map((cmd) => cmd.invocationName),
        imageNames: runner
          .getRegisteredCommands()
          .filter((cmd) => cmd.name === "image")
          .map((cmd) => cmd.invocationName),
      };
    };

    check(
      "normal install handles /b-image via input and advertises it",
      await runCommandResolution([previewExtPath]),
      {
        errors: 0,
        inputAction: "handled",
        hintAdvertisesBImage: true,
        bImagePath: null,
        bareImagePath: null,
        bImageNames: [],
        imageNames: [],
      },
    );
    check(
      "non-tui json mode passes /b-image through",
      await runCommandResolution([previewExtPath], { mode: "json" }),
      {
        errors: 0,
        inputAction: "continue",
        hintAdvertisesBImage: false,
        bImagePath: null,
        bareImagePath: null,
        bImageNames: [],
        imageNames: [],
      },
    );
    check(
      "coexistence keeps top-level /image intact beside /b-image",
      await runCommandResolution([existingImageTop, previewExtPath]),
      {
        errors: 0,
        inputAction: "handled",
        hintAdvertisesBImage: true,
        bImagePath: null,
        bareImagePath: existingImageTop,
        bImageNames: [],
        imageNames: ["image"],
      },
    );
    check(
      "coexistence keeps late session_start /image intact beside /b-image",
      await runCommandResolution([previewExtPath, existingImageSession]),
      {
        errors: 0,
        inputAction: "handled",
        hintAdvertisesBImage: true,
        bImagePath: null,
        bareImagePath: existingImageSession,
        bImageNames: [],
        imageNames: ["image"],
      },
    );
    check(
      "coexistence with image.md still handles /b-image",
      await runCommandResolution([previewExtPath], {
        preloadedPrompts: ["image"],
      }),
      {
        errors: 0,
        inputAction: "handled",
        hintAdvertisesBImage: true,
        bImagePath: null,
        bareImagePath: null,
        bImageNames: [],
        imageNames: [],
      },
    );
    check(
      "coexistence yields to late session_start /b-image extension",
      await runCommandResolution([previewExtPath, existingBImage]),
      {
        errors: 0,
        inputAction: "continue",
        hintAdvertisesBImage: false,
        bImagePath: existingBImage,
        bareImagePath: null,
        bImageNames: ["b-image"],
        imageNames: [],
      },
    );
    check(
      "coexistence yields to resources_discover b-image.md on startup",
      await runCommandResolution([previewExtPath, latePromptExt], {
        discoverLateTemplateOn: "startup",
      }),
      {
        errors: 0,
        inputAction: "continue",
        hintAdvertisesBImage: false,
        bImagePath: null,
        bareImagePath: null,
        bImageNames: [],
        imageNames: [],
      },
    );
    check(
      "coexistence yields to resources_discover b-image.md on reload",
      await runCommandResolution([previewExtPath, latePromptExt], {
        discoverLateTemplateOn: "reload",
      }),
      {
        errors: 0,
        inputAction: "continue",
        hintAdvertisesBImage: false,
        bImagePath: null,
        bareImagePath: null,
        bImageNames: [],
        imageNames: [],
      },
    );
    check(
      "R5-3: extension-sourced /b-image 1 passes through unchanged in TUI mode",
      await runCommandResolution([previewExtPath], {
        inputSource: "extension",
      }),
      {
        errors: 0,
        inputAction: "continue",
        hintAdvertisesBImage: true,
        bImagePath: null,
        bareImagePath: null,
        bImageNames: [],
        imageNames: [],
      },
    );

    // The probe script requires a minimum count: an empty or partial run must not pass.
    results._count = Object.keys(results).length;
    writeFileSync(out, JSON.stringify(results, null, 1));
  });
}
