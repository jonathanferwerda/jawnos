#!/usr/bin/env python3
"""Turn the Android captures into the `#phone` wall on jawnos.ca.

    python3 scripts/gallery/android_publish.py
    python3 scripts/gallery/android_publish.py --deploy both

Reads the manifest (`android-scenes.json`) and the PNGs in
`.shots/android-scenes/`, writes full and thumbnail WebP files into the site's
`assets/gallery/`, and rewrites the block between `android:generated` markers
in `index.html`. Nothing is written until every included capture exists, so a
partial run cannot blank the live section.
"""
from __future__ import annotations

import argparse
import html
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_SITE = REPO.parent / "jawnos-website"
DEFAULT_MANIFEST = Path(__file__).resolve().parent / "android-scenes.json"
DEFAULT_SHOTS = REPO / ".shots" / "android-scenes"
START = "<!-- android:generated:start -->"
END = "<!-- android:generated:end -->"


def run(cmd, cwd=None):
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(str(c) for c in cmd)}\n{result.stderr.strip()}")
    return result.stdout


def identify(path: Path) -> tuple[int, int]:
    out = run(["magick", "identify", "-format", "%w %h", str(path)])
    width, height = out.split()
    return int(width), int(height)


def write_webp(src: Path, dest: Path, box: str, quality: int):
    # box is a full ImageMagick geometry: "1080x>" bounds the width only, so a
    # tall capture keeps its native width ("1080x1080>" would squeeze the
    # 2400 px phone screen down to 486 px).
    run(["magick", str(src), "-colorspace", "sRGB", "-resize", box,
         "-quality", str(quality), "-define", "webp:method=6", str(dest)])


def figure_block(scene: dict, thumb_size: tuple[int, int]) -> str:
    slug = scene["slug"]
    title = html.escape(scene["title"], quote=False)
    desc = html.escape(scene["description"], quote=False)
    alt = html.escape(scene["alt"], quote=True)
    width, height = thumb_size
    return f'''        <figure class="phone" data-reveal>
          <a class="phone-frame" href="assets/gallery/{slug}.webp" data-shot>
            <img src="assets/gallery/{slug}-thumb.webp" alt="{alt}" width="{width}" height="{height}" loading="lazy" decoding="async">
            <span class="shot-zoom" aria-hidden="true">Open full size</span>
          </a>
          <figcaption>
            <strong>{title}</strong>
            <span>{desc}</span>
          </figcaption>
        </figure>'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shots", default=str(DEFAULT_SHOTS))
    parser.add_argument("--site", default=str(DEFAULT_SITE))
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument("--deploy", choices=("pages", "50webs", "both"), default=None)
    args = parser.parse_args()

    shots = Path(args.shots).expanduser().resolve()
    site = Path(args.site).expanduser().resolve()
    manifest = json.loads(Path(args.manifest).read_text())
    scenes = manifest.get("scenes") or []
    if not scenes:
        raise SystemExit("android_publish: no scenes in the manifest")

    missing = [s["file"] for s in scenes if not (shots / (s["file"] + ".png")).is_file()]
    if missing:
        raise SystemExit("android_publish: missing captures: " + ", ".join(missing))

    gallery = site / "assets" / "gallery"
    gallery.mkdir(parents=True, exist_ok=True)
    thumbs = {}
    for scene in scenes:
        src = shots / (scene["file"] + ".png")
        full = gallery / (scene["slug"] + ".webp")
        thumb = gallery / (scene["slug"] + "-thumb.webp")
        # the lightbox shows the capture at its native width; the wall uses the
        # small thumb, so keep the full one sharp (the screenshots are UI text)
        write_webp(src, full, "1080x>", 94)
        write_webp(src, thumb, "420x420>", 82)
        thumbs[scene["slug"]] = identify(thumb)

    index = site / "index.html"
    text = index.read_text()
    if START not in text or END not in text:
        raise SystemExit("android_publish: android:generated markers not in index.html")
    before, rest = text.split(START, 1)
    _, after = rest.split(END, 1)
    figures = "\n\n".join(figure_block(s, thumbs[s["slug"]]) for s in scenes)
    block = f"\n      <div class=\"phone-wall\">\n{figures}\n      </div>\n      "
    index.write_text(before + START + block + END + after)

    print(f"published {len(scenes)} phone screens to {gallery}")

    if args.deploy in ("pages", "both"):
        print(run([str(site / "deploy-pages.sh")], cwd=site).strip())
    if args.deploy in ("50webs", "both"):
        print(run([sys.executable, str(site / "deploy.py")], cwd=site).strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
