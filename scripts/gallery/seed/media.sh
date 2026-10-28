#!/bin/sh
# Generate the demo's photos, music, documents, maps and wallpapers, then copy
# them into the QEMU guest's home directory.
#
#   scripts/gallery/seed/media.sh              generate + copy to the guest
#   scripts/gallery/seed/media.sh --stage-only only fill .shots/demo_media
#
# ImageMagick provides the art; ffmpeg makes the short tracks. The guest's
# gallery_seed.py indexes every image in each album directory, so the exact
# files do not matter as long as the album folders exist.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
STAGE=${STAGE:-$ROOT/.shots/demo_media}
TABLE=${TABLE:-jawn@table.jonathanferwerda.com}
TABLE_SSH=${TABLE_SSH:-8022}
GUEST_SSH=${GUEST_SSH:-2222}
STAGE_ONLY=0
[ "${1:-}" = "--stage-only" ] && STAGE_ONLY=1

IMG=$(command -v magick || command -v convert || true)
[ -n "$IMG" ] || { echo "media.sh: ImageMagick (magick or convert) is required" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/Pictures/T-Watch" "$STAGE/Pictures/T-Deck" \
  "$STAGE/Pictures/Studio" "$STAGE/Pictures/Plein Air" "$STAGE/Pictures/Portraits" \
  "$STAGE/Pictures/Maps" "$STAGE/Pictures/travel" "$STAGE/Pictures/Backgrounds" \
  "$STAGE/Music/Night Studio" "$STAGE/Music/Morning Light" "$STAGE/Music/Field Notes" \
  "$STAGE/Documents"

# ---- photos ---------------------------------------------------------------
photo() {
  out=$1; a=$2; b=$3; c=$4; label=$5; sub=$6
  "$IMG" -size 1600x1200 gradient:"$a-$b" -blur 0x3 \
    -fill "$c" -draw 'circle 1180,320 1180,120' \
    -fill "$b" -draw 'roundrectangle 160,760 760,980 16,16' \
    -fill "$a" -draw 'roundrectangle 240,820 680,920 10,10' \
    -fill '#eceff4' -pointsize 54 -gravity northwest -annotate +120+110 "$label" \
    -fill '#d8dee9' -pointsize 26 -gravity northwest -annotate +124+190 "$sub" "$out"
}

photo "$STAGE/Pictures/T-Watch/01.jpg"   '#1a1f27' '#4c566a' '#88c0d0' 'JAWNOS WATCH' 'steps · sleep · heart'
photo "$STAGE/Pictures/T-Watch/02.jpg"   '#2e3440' '#5e81ac' '#a3be8c' 'T-DECK' 'LoRa · maps · notes'
photo "$STAGE/Pictures/T-Watch/03.jpg"   '#3b4252' '#81a1c1' '#88c0d0' 'JAWNOS' 'a computer in your pocket'
photo "$STAGE/Pictures/T-Watch/04.jpg"   '#2e3440' '#5e81ac' '#d08770' 'T-WATCH · SIDE' 'wearable mesh'
for n in 1 2 3 4; do
  photo "$STAGE/Pictures/T-Deck/0$n.jpg" '#1a1f27' '#88c0d0' '#a3be8c' "T-DECK 0$n" 'field notes · mesh · maps'
done
photo "$STAGE/Pictures/Studio/01.jpg"      '#2e3440' '#5e81ac' '#d08770' 'Harbour, underlayer' 'oil on linen'
photo "$STAGE/Pictures/Studio/02.jpg"      '#3b4252' '#8fbcbb' '#ebcb8b' 'Studio wall, October' 'work in progress'
photo "$STAGE/Pictures/Studio/03.jpg"      '#1a1f27' '#81a1c1' '#b48ead' 'Blue study' 'cold light'
photo "$STAGE/Pictures/Studio/04.jpg"      '#2e3440' '#a3be8c' '#88c0d0' 'The long table' 'six studies'
photo "$STAGE/Pictures/Plein Air/01.jpg"   '#2e3440' '#a3be8c' '#ebcb8b' 'Ravine, morning' 'plein air'
photo "$STAGE/Pictures/Plein Air/02.jpg"   '#1a1f27' '#88c0d0' '#5e81ac' 'Waterline' 'harbour'
photo "$STAGE/Pictures/Plein Air/03.jpg"   '#3b4252' '#d08770' '#a3be8c' 'Field edge' 'late summer'
photo "$STAGE/Pictures/Plein Air/04.jpg"   '#2e3440' '#ebcb8b' '#bf616a' 'Late light' 'the walk home'
photo "$STAGE/Pictures/Portraits/01.jpg"   '#3b4252' '#b48ead' '#d8dee9' 'Ruth, reading' 'portrait'
photo "$STAGE/Pictures/Portraits/02.jpg"   '#2e3440' '#d08770' '#eceff4' 'Eleanor' 'portrait'
photo "$STAGE/Pictures/Portraits/03.jpg"   '#1a1f27' '#8fbcbb' '#a3be8c' 'Jonah' 'portrait'
photo "$STAGE/Pictures/Portraits/04.jpg"   '#2e3440' '#5e81ac' '#bf616a' 'Self, winter' 'portrait'

# ---- maps and wallpapers --------------------------------------------------
# A printed street map: paper ground, water on the west, a grid of streets, a
# park and the labels a person would letter onto it. The map engine draws the
# plate at 0.92 alpha over its own canvas, so the art stays light and legible.
"$IMG" -size 1600x1200 xc:'#e9e5d9' \
  -fill '#b9d3dd' -draw "path 'M 0,0 L 300,0 C 250,180 330,330 275,520 C 222,700 320,880 268,1200 L 0,1200 Z'" \
  -fill '#a9c8d4' -draw "path 'M 0,0 L 210,0 C 165,180 240,330 190,520 C 140,700 232,880 185,1200 L 0,1200 Z'" \
  -fill '#cbdcc0' -draw 'roundrectangle 1020,150 1500,470 26,26' \
  -fill '#c6d9ba' -draw 'circle 1140,780 1140,690' \
  -fill '#dcd8ca' -draw 'roundrectangle 360,180 760,360 8,8' \
  -draw 'roundrectangle 830,520 1110,700 8,8' \
  -draw 'roundrectangle 400,820 700,1060 8,8' \
  -draw 'roundrectangle 1180,880 1480,1080 8,8' \
  -stroke '#ffffff' -strokewidth 22 -fill none \
  -draw 'line 340,90 340,1200' -draw 'line 520,90 520,1200' \
  -draw 'line 700,90 700,1200' -draw 'line 880,90 880,1200' \
  -draw 'line 1060,90 1060,1200' -draw 'line 1240,90 1240,1200' \
  -draw 'line 360,110 1600,110' -draw 'line 360,300 1600,300' \
  -draw 'line 360,500 1600,500' -draw 'line 360,700 1600,700' \
  -draw 'line 360,900 1600,900' -draw 'line 360,1090 1600,1090' \
  -stroke '#f0c98a' -strokewidth 26 -draw 'line 320,760 1600,690' \
  -stroke '#e3b877' -strokewidth 18 -draw 'line 600,0 660,1200' \
  -stroke '#b9b3a1' -strokewidth 5 \
  -draw 'line 340,0 276,520' -draw 'line 276,520 185,1200' \
  -fill '#5d5c54' -stroke none -pointsize 46 -gravity northwest -annotate +380+26 'SARNIA' \
  -pointsize 22 -annotate +384+76 'HARBOURFRONT' \
  -pointsize 20 -fill '#77766c' -annotate +700+340 'MARKET' -annotate +1030+470 'PARK' \
  -annotate +120+560 'HARBOUR' -annotate +60+640 'MARINA' \
  -fill '#8a8878' -pointsize 15 -annotate +560+286 'MARKET ST' -annotate +560+486 'QUEEN ST' \
  -annotate +560+686 'HARBOUR RD' -annotate +560+886 'RAVINE RD' \
  "$STAGE/Pictures/travel/harbour.jpg"

"$IMG" -size 1200x900 xc:'#e6e8da' \
  -fill '#c3d9bd' -draw 'roundrectangle 60,60 1140,840 40,40' \
  -fill '#b2cfc9' -draw "path 'M 120,0 C 210,140 160,260 250,380 C 340,500 300,640 400,760 C 470,848 520,870 560,900 L 700,900 C 640,840 600,780 540,690 C 450,560 500,430 410,300 C 330,180 370,80 310,0 Z'" \
  -fill '#a8c6a0' -draw 'circle 900,220 900,80' -draw 'circle 280,720 280,600' \
  -stroke '#d8c9a0' -strokewidth 9 -fill none \
  -draw "path 'M 0,500 C 220,480 360,520 560,470 C 760,420 920,460 1200,400'" \
  -stroke '#c9a877' -strokewidth 7 \
  -draw "path 'M 150,880 C 320,720 430,640 560,540 C 700,430 830,300 1000,120'" \
  -stroke '#e9e2cf' -strokewidth 4 -draw "path 'M 640,760 C 720,660 820,600 960,560 C 1040,540 1120,500 1180,460'" \
  -fill '#4f5447' -stroke none -pointsize 40 -gravity northwest -annotate +72+72 'RAVINE PARK' \
  -pointsize 18 -fill '#6d7364' -annotate +76+124 'river trail · 4.2 km loop' \
  -annotate +620+560 'THE BEND' -annotate +300+700 'CEDAR STAND' \
  -fill '#7e8374' -pointsize 15 -annotate +210+470 'RIVER PATH' \
  "$STAGE/Pictures/travel/ravine.jpg"

"$IMG" -size 1920x1080 gradient:'#101a26-#3b5570' -blur 0x1 \
  -fill '#6d8496' -draw 'circle 1450,220 1450,90' \
  -fill '#0e1a24' -draw "path 'M 0,700 L 520,640 L 980,700 L 1400,650 L 1920,710 L 1920,1080 L 0,1080 Z'" \
  -fill '#4a6a5e' -draw 'circle 320,760 320,690' -blur 0x6 -modulate 92,88,100 \
  "$STAGE/Pictures/Backgrounds/harbour-dawn.jpg"
"$IMG" -size 1920x1080 plasma:'#3a2b22-#7a5a3f' -blur 0x10 \
  -fill '#f3d9a6' -draw 'roundrectangle 1180,150 1660,760 30,30' \
  -fill '#2b2019' -draw 'roundrectangle 1210,180 1630,730 20,20' \
  -blur 0x14 -modulate 96,92,100 "$STAGE/Pictures/Backgrounds/studio-window.jpg"
"$IMG" -size 1920x1080 plasma:'#21301f-#63775a' -blur 0x12 \
  -fill '#9fb08c' -draw 'circle 1580,180 1580,60' \
  -fill '#16241a' -draw 'circle 260,900 260,690' -draw 'circle 760,980 760,740' \
  -blur 0x18 -modulate 90,90,100 "$STAGE/Pictures/Backgrounds/forest-edge.jpg"
"$IMG" -size 1920x1080 radial-gradient:'#6d6252-#2f2a24' -blur 0x3 \
  "$STAGE/Pictures/Backgrounds/paper-desk.jpg"

# ---- music ----------------------------------------------------------------
if command -v ffmpeg >/dev/null; then
  i=0
  while IFS='|' read -r album title f1 f2; do
    i=$((i+1))
    ffmpeg -nostdin -loglevel error -y \
      -f lavfi -i "sine=frequency=$f1:duration=72" \
      -f lavfi -i "sine=frequency=$f2:duration=72" \
      -filter_complex '[0][1]amix=inputs=2,volume=0.16,aecho=0.8:0.7:600:0.32' \
      -metadata title="$title" -metadata artist='Mara Ellison' -metadata album="$album" \
      -c:a libmp3lame -q:a 4 "$STAGE/Music/$album/$(printf '%02d' "$i") - $title.mp3"
  done <<'TRACKS'
Night Studio|Harbour Light|220|330
Night Studio|Underlayer|196|294
Night Studio|Blue Study|174|261
Morning Light|Window|261|392
Morning Light|Paper|246|369
Morning Light|First Coffee|220|277
Field Notes|Ravine|196|247
Field Notes|Waterline|174|220
Field Notes|Long Table|233|349
TRACKS
  for album in 'Night Studio' 'Morning Light' 'Field Notes'; do
    "$IMG" -size 700x700 gradient:'#2e3440-#5e81ac' -fill '#eceff4' -pointsize 40 \
      -gravity center -annotate +0-40 "$album" -pointsize 22 -annotate +0+30 'Mara Ellison' \
      "$STAGE/Music/$album/cover.jpg"
  done
else
  echo "media.sh: ffmpeg not found; skipping the music tracks" >&2
fi

# ---- documents ------------------------------------------------------------
cat > "$STAGE/Documents/Northlight — wall plan.md" <<'EOF'
# Northlight Gallery — wall plan

The show opens on the 14th. Six pieces, the harbour series at the centre.

- Wall A: three small studies, hung low.
- Wall B: the large underlayer, spot at 45°.
- Wall C: the blue study, paired with the maquette.

Framer delivers Tuesday. Van booked for 8am.
EOF
cat > "$STAGE/Documents/Studio notes.md" <<'EOF'
# Studio notes

The underlayer needs another day before the glaze. Keep the edges open.

Paper order: 300 gsm cold press, two rolls. Invoice Northlight after delivery.
EOF
cat > "$STAGE/Documents/Meridian — lobby proposal.md" <<'EOF'
# Meridian Health — lobby proposal

Three panels, 120 × 180 cm, in the harbour palette. The board approved the
commission on the 12th. Installation window is the first week of December.
EOF

echo "media: $(find "$STAGE" -type f | wc -l) files, $(du -sh "$STAGE" | cut -f1) in $STAGE"
[ "$STAGE_ONLY" = 1 ] && exit 0

# ---- copy to the guest ----------------------------------------------------
tar -C "$STAGE" -cf - . | ssh -T -p "$TABLE_SSH" -o BatchMode=yes "$TABLE" \
  "ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new -p $GUEST_SSH jawn@127.0.0.1 \
   'tar -C /home/jawn -xf - && test -d /home/jawn/Pictures/Portraits && echo media: copied'"
