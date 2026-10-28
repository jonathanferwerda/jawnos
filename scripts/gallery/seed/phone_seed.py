#!/usr/bin/env python3
"""Build the demo database the Android screenshots start from.

The desktop gallery seed (``demo.db``) is made on a Linux guest whose home is
``/home/jawn``. A phone keeps its media on shared storage (``/sdcard``) and its
settings rows belong to the device called ``mobile``, so the same data has to
be re-homed before it is placed in the app's tree.

    scripts/gallery/seed/media.sh --stage-only          # once, fills .shots/demo_media
    python3 scripts/gallery/seed/phone_seed.py \\
        --seed .shots/demo.db --out .shots/phone-demo.db

The result is copied to the app's ``database/jawnos.db`` by
``scripts/gallery/android.sh``. It runs the extra and gallery seeds against the
staged media tree, so the album and map rows name files that really exist on
the phone.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEFAULT_SEED = REPO / ".shots" / "demo.db"
DEFAULT_OUT = REPO / ".shots" / "phone-demo.db"
DEFAULT_MEDIA = REPO / ".shots" / "demo_media"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--seed", default=str(DEFAULT_SEED),
                    help="desktop demo database (default: .shots/demo.db)")
parser.add_argument("--out", default=str(DEFAULT_OUT),
                    help="where to write the phone database (default: .shots/phone-demo.db)")
parser.add_argument("--media", default=str(DEFAULT_MEDIA),
                    help="staged media tree (default: .shots/demo_media)")
parser.add_argument("--home", default="/sdcard",
                    help="shared-storage root the media paths are re-homed to (default: /sdcard)")
parser.add_argument("--device", default="mobile",
                    help="the device name the settings rows belong to (default: mobile)")
args = parser.parse_args()

seed = Path(args.seed).expanduser().resolve()
out = Path(args.out).expanduser().resolve()
media = Path(args.media).expanduser().resolve()
home = args.home.rstrip("/") or "/sdcard"
device = args.device.strip() or "mobile"

for need in (seed, media / "Pictures" / "Studio", media / "Pictures" / "travel"):
    if not need.exists():
        raise SystemExit(f"phone_seed: missing {need}\n"
                         "  run scripts/gallery/seed/media.sh --stage-only first")

shutil.copyfile(seed, out)

# The extra and gallery seeds find their files through HOME, so point HOME at
# the staged tree. Their rows then carry the staging path, which is rewritten
# below to the phone's shared storage.
env = dict(os.environ)
env["HOME"] = str(media)
for script in ("demo_extra_seed.py", "gallery_seed.py"):
    result = subprocess.run(
        [sys.executable, str(HERE / script), str(out)],
        env=env, capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"phone_seed: {script} failed\n{result.stdout}{result.stderr}")
    for line in result.stdout.strip().splitlines():
        print(f"  {script}: {line}")

db = sqlite3.connect(out)
cur = db.cursor()

# The manager caches a photo's thumbnail under Pictures/<app>/.thumbs and looks
# for the album under the app's own name. The staged albums are named for people
# ("Plein Air"), so give each one an app-named copy with its thumbnails ready;
# otherwise the gallery falls back to an on-demand thumb path that Android's
# ImageMagick never gets a chance to write.
ALBUMS = {
    "t-watch": "T-Watch",
    "t-deck": "T-Deck",
    "studio": "Studio",
    "plein_air": "Plein Air",
    "portraits": "Portraits",
}
imagemagick = shutil.which("magick") or shutil.which("convert")
thumbs = 0
for app, display in ALBUMS.items():
    src_dir = media / "Pictures" / display
    if not src_dir.is_dir():
        continue
    dst_dir = media / "Pictures" / app
    (dst_dir / ".thumbs").mkdir(parents=True, exist_ok=True)
    for src in sorted(src_dir.iterdir()):
        if src.suffix.lower() not in (".jpg", ".jpeg", ".png"):
            continue
        dst = dst_dir / src.name
        if not dst.exists():
            shutil.copy2(src, dst)
        thumb = dst_dir / ".thumbs" / (src.stem + ".png")
        if imagemagick and not thumb.exists():
            subprocess.run(
                [imagemagick, str(dst), "-auto-orient", "-strip",
                 "-resize", "200x200", str(thumb)],
                capture_output=True,
            )
        if thumb.exists() and thumb.stat().st_size > 0:
            thumbs += 1

# Name the album rows for the app folders the manager expects, and point each
# photo at the thumbnail that is now beside it.
for app in ALBUMS:
    for uuid, file_json in cur.execute(
        "select uuid, file from appointments where app=?", (app,)
    ).fetchall():
        try:
            files = json.loads(file_json)
        except (TypeError, ValueError):
            continue
        for f in files:
            src = f.get("f") or ""
            if not src:
                continue
            name = Path(src).name
            stem = Path(src).stem
            f["f"] = f"{home}/Pictures/{app}/{name}"
            if (media / "Pictures" / app / ".thumbs" / (stem + ".png")).exists():
                f["thumb"] = f"{home}/Pictures/{app}/.thumbs/{stem}.png"
        cur.execute(
            "update appointments set file=? where uuid=?",
            (json.dumps(files, separators=(",", ":")), uuid),
        )

# 1. Re-home every absolute media path in the JSON-bearing columns.
prefix = str(media)
for table, columns in (
    ("appointments", ("file", "data")),
    ("settings", ("value",)),
    ("continent", ("file",)),
    ("warehouse", ("file",)),
):
    exists = cur.execute(
        "select 1 from sqlite_master where type='table' and name=?", (table,)
    ).fetchone()
    if not exists:
        continue
    present = {row[1] for row in cur.execute(f"pragma table_info({table})")}
    for column in columns:
        if column not in present:
            continue
        cur.execute(
            f"update {table} set {column} = replace({column}, ?, ?) "
            f"where {column} like ?",
            (prefix, home, f"%{prefix}%"),
        )

# 2. The phone's settings rows are its own: the desktop's `computer` rows are
#    re-homed to the device the app reports, so colours, visibility and the
#    clothesline are the ones a person sees on the phone.
cur.execute("update settings set device=? where device='computer'", (device,))

db.commit()

apps = cur.execute("select count(distinct app) from appointments").fetchone()[0]
rows = cur.execute("select count(*) from appointments").fetchone()[0]
settings = cur.execute("select count(*) from settings").fetchone()[0]
albums = cur.execute(
    "select count(distinct app) from appointments "
    "where app in ('t-watch','t-deck','studio','plein_air','portraits')"
).fetchone()[0]
print(f"phone seed: {out}")
print(f"  appointments {rows} across {apps} apps, {settings} settings, {albums} albums, {thumbs} thumbnails")
print(f"  paths re-homed {prefix} -> {home}; settings device -> {device}")
db.close()
