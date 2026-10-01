// Test-only extension for tests/pi/input-image-preview-probe.sh. At session start it exercises
// the pure parts of pi/extensions/b-input-image-preview.ts (path extraction, clipboard-path
// labels, the recent-preview list behind /image, popup-slot ownership, bounded file read) and
// writes one JSON result per case to $PROBE_OUT. Rendering, the popup, and mouse input need a
// terminal and are not covered.
import { mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  PopupSlot,
  RecentImages,
  extractImagePaths,
  imageLabel,
  isClipboardImagePath,
  loadImage,
  parseImageIndex,
} from "../../pi/extensions/b-input-image-preview.ts";

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

    // /image reads the latest non-empty preview; an empty render keeps it (the command line
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

    // /image argument: whole-string positive integer only.
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

    // The probe script requires a minimum count: an empty or partial run must not pass.
    results._count = Object.keys(results).length;
    writeFileSync(out, JSON.stringify(results, null, 1));
  });
}
