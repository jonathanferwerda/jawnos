#!/usr/bin/env python3
"""Turn a captured scene set into the jawnos.ca screenshot gallery.

Reads the scene manifest and the PNGs (plus rects.json) written by
scripts/gallery/capture.mjs, crops each window from its recorded rectangle,
writes full and thumbnail WebP files into the site's assets/gallery/, and
rewrites the block between the gallery:generated markers in index.html.

    python3 scripts/gallery/publish.py --shots .shots/scenes-live
    python3 scripts/gallery/publish.py --shots .shots/scenes-live --deploy pages
    python3 scripts/gallery/publish.py --shots .shots/scenes-live --deploy both

Nothing is written until every included scene has a usable PNG, so a partial
capture cannot blank the live gallery.
"""
from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_SITE = REPO.parent / "jawnos-website"
DEFAULT_MANIFEST = Path(__file__).resolve().parent / "scenes.json"
DEFAULT_SHOTS = REPO / ".shots" / "scenes-live"
START = "<!-- gallery:generated:start -->"
END = "<!-- gallery:generated:end -->"


def run(cmd, cwd=None):
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(str(c) for c in cmd)}\n{result.stderr.strip()}")
    return result.stdout


def identify(path: Path) -> tuple[int, int]:
    out = run(["magick", "identify", "-format", "%w %h", str(path)])
    width, height = out.split()
    return int(width), int(height)


def write_webp(src: Path, dest: Path, crop, max_w: int, quality: int):
    cmd = ["magick", str(src)]
    if crop:
        x, y, w, h = crop
        cmd += ["-crop", f"{w}x{h}+{x}+{y}", "+repage"]
    cmd += ["-colorspace", "sRGB", "-resize", f"{max_w}x{max_w}>",
            "-quality", str(quality), "-define", "webp:method=6", str(dest)]
    run(cmd)


def clamp_crop(rect, size):
    x, y, w, h = rect
    max_w, max_h = size
    x = max(0, min(int(x), max_w - 1))
    y = max(0, min(int(y), max_h - 1))
    w = max(1, min(int(w), max_w - x))
    h = max(1, min(int(h), max_h - y))
    return [x, y, w, h]


def scene_block(scene, sizes, lead):
    site = scene["site"]
    slug = site["slug"]
    title = html.escape(site["title"], quote=False)
    desc = html.escape(site["description"], quote=False)
    alt = html.escape(site["alt"], quote=True)
    image = f"assets/gallery/{slug}.webp" if lead else f"assets/gallery/{slug}-thumb.webp"
    width, height = sizes[slug]["full" if lead else "thumb"]
    cls = "shot shot--lead" if lead else "shot"
    pad = "      " if lead else "        "
    lines = [
        f'{pad}<figure class="{cls}" data-reveal>',
        f'{pad}  <a class="shot-frame" href="assets/gallery/{slug}.webp" data-shot>',
        f'{pad}    <img src="{image}" alt="{alt}" width="{width}" height="{height}" loading="lazy" decoding="async">',
    ]
    if lead:
        lines.append(f'{pad}    <span class="shot-zoom" aria-hidden="true">Open full size</span>')
    lines += [
        f'{pad}  </a>',
        f'{pad}  <figcaption>',
        f'{pad}    <strong>{title}</strong>',
        f'{pad}    <span>{desc}</span>',
        f'{pad}  </figcaption>',
        f'{pad}</figure>',
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shots", default=str(DEFAULT_SHOTS), help="capture output directory")
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST), help="scene manifest")
    parser.add_argument("--site", default=str(DEFAULT_SITE), help="jawnos-website directory")
    parser.add_argument("--deploy", nargs="?", const="pages",
                        choices=("pages", "50webs", "both"), default=None,
                        help="upload afterwards: Cloudflare Pages (default), 50webs, or both")
    parser.add_argument("--no-build", action="store_true", help="skip build_pages.sh")
    args = parser.parse_args()

    shots = Path(args.shots)
    site = Path(args.site)
    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    defaults = manifest.get("defaults", {})
    included = [s for s in manifest.get("scenes", []) if (s.get("site") or {}).get("include")]
    if not included:
        raise SystemExit("publish: no scenes with site.include")

    rects_path = shots / "rects.json"
    rects = json.loads(rects_path.read_text(encoding="utf-8")) if rects_path.exists() else {}

    # Validate every input before touching the site.
    missing = [s["id"] for s in included if not (shots / f"{s['id']}.png").exists()]
    if missing:
        raise SystemExit("publish: missing captures: " + ", ".join(missing))
    shots_info_path = shots / "shots.json"
    if shots_info_path.exists():
        info = json.loads(shots_info_path.read_text(encoding="utf-8"))
        failed = {r["id"] for r in info.get("scenes", []) if r.get("site") and not r.get("ok")}
        broken = [s["id"] for s in included if s["id"] in failed]
        if broken:
            raise SystemExit("publish: capture failed for: " + ", ".join(broken))

    gallery = site / "assets" / "gallery"
    gallery.mkdir(parents=True, exist_ok=True)

    sizes = {}
    written = set()
    for scene in included:
        slug = scene["site"]["slug"]
        src = shots / f"{scene['id']}.png"
        size = identify(src)
        crop = None
        if scene["site"].get("crop") == "window":
            rect = rects.get(scene["id"]) or scene.get("window") or defaults.get("window")
            if rect:
                crop = clamp_crop([rect[0] - 6, rect[1] - 6, rect[2] + 12, rect[3] + 12], size)
            else:
                print(f"publish: warning: no rect for {scene['id']}, using the full frame", file=sys.stderr)

        full = gallery / f"{slug}.webp"
        thumb = gallery / f"{slug}-thumb.webp"
        write_webp(src, full, crop, 1600, 84)
        write_webp(src, thumb, crop, 760, 80)
        sizes[slug] = {"full": identify(full), "thumb": identify(thumb)}
        written.update({full.name, thumb.name})
        print(f"  {scene['id']:<26} -> {slug}.webp  {sizes[slug]['full'][0]}x{sizes[slug]['full'][1]}")

    lead_scenes = [s for s in included if s["site"].get("lead")]
    if len(lead_scenes) != 1:
        raise SystemExit(f"publish: expected exactly one lead scene, found {len(lead_scenes)}")
    lead = lead_scenes[0]

    parts = [scene_block(lead, sizes, True), "", '      <div class="shot-wall">']
    for scene in included:
        if scene is lead:
            continue
        parts.append(scene_block(scene, sizes, False))
        parts.append("")
    parts.append("      </div>")
    block = "\n".join(parts)

    index = site / "index.html"
    text = index.read_text(encoding="utf-8")
    pattern = re.compile(re.escape(START) + r".*?" + re.escape(END), re.S)
    matches = pattern.findall(text)
    if len(matches) != 1:
        raise SystemExit("publish: index.html needs exactly one gallery:generated marker pair")

    def replacement(match):
        return START + "\n" + block + "\n      " + END

    index.write_text(pattern.sub(replacement, text, count=1), encoding="utf-8")

    # Remove only gallery WebP files this run did not produce.
    for stale in gallery.glob("*.webp"):
        if stale.name not in written:
            stale.unlink()

    total = sum((gallery / name).stat().st_size for name in written)
    print(f"gallery: {len(included)} images, {total / 1024:.0f} KB, index.html updated")

    if not args.no_build:
        print(run(["./build_pages.sh"], cwd=site).strip())

    if args.deploy in ("pages", "both"):
        if not (site / "pages.env").exists():
            raise SystemExit("publish: --deploy pages needs pages.env (see the site README)")
        print(run(["./deploy-pages.sh"], cwd=site).strip())
    if args.deploy in ("50webs", "both"):
        if not (site / "deploy.env").exists():
            raise SystemExit("publish: --deploy 50webs needs deploy.env (see the site README)")
        print(run([sys.executable, "deploy.py"], cwd=site).strip())
    if args.deploy:
        print("deployed")


if __name__ == "__main__":
    main()
