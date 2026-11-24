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
# The albums hold small painted scenes, not photographs of anyone: layered
# skies, hills and water for the plein-air and device albums, silhouetted
# portraits for Portraits, and studio abstracts for Studio. They are generated
# so the demo never carries a real person's picture.
LOGO=$ROOT/public/images/jbuttons/logo2.png
[ -f "$LOGO" ] || LOGO=$ROOT/../jawnos-website/assets/logo2-art.png
[ -f "$LOGO" ] || { echo "media.sh: the JawnOS logo is required for the marker landscape" >&2; exit 1; }

landscape() {
  out=$1; sky1=$2; sky2=$3; far=$4; mid=$5; near=$6; water=$7; sun=$8; logo=${9:-0}
  "$IMG" -size 1600x1200 gradient:"$sky1-$sky2" \
    -fill "$sun" -draw 'circle 1160,330 1160,272' \
    -fill 'rgba(255,232,185,0.28)' -draw 'circle 1160,330 1160,205' -blur 0x32 \
    -fill "$far" -draw "path 'M 0,700 C 220,640 430,680 640,650 C 850,620 1000,665 1200,640 C 1360,620 1500,655 1600,640 L 1600,810 L 0,810 Z'" \
    -fill "$mid" -draw "path 'M 0,805 C 260,740 520,785 790,758 C 1050,730 1310,775 1600,748 L 1600,950 L 0,950 Z'" \
    -fill "$near" -draw "path 'M 0,940 C 300,890 610,920 900,900 C 1200,880 1450,910 1600,890 L 1600,1200 L 0,1200 Z'" \
    -fill "$water" -draw "path 'M 470,1200 C 610,1030 760,990 900,880 C 980,820 1060,810 1140,780 L 1215,780 C 1115,830 1015,870 955,940 C 855,1050 755,1110 715,1200 Z'" \
    -fill 'rgba(255,225,170,0.18)' -draw "path 'M 1115,800 L 1205,800 L 1180,1150 L 1100,1150 Z'" -blur 0x14 \
    -fill "$near" -draw 'circle 155,1035 155,895' -draw 'circle 300,1055 300,925' -draw 'circle 1450,1055 1450,915' \
    -stroke 'rgba(255,240,210,0.55)' -strokewidth 3 -fill none \
    -draw 'path "M 380,420 l 18,-12 l 18,12"' -draw 'path "M 430,390 l 14,-9 l 14,9"' -draw 'path "M 470,430 l 12,-8 l 12,8"' \
    \( -size 1600x1200 plasma:'#ffffff-#000000' -blur 0x4 \) -compose soft-light -define compose:args=10 -composite \
    +noise Gaussian -attenuate 0.015 -quality 92 "$out"
  if [ "$logo" = 1 ]; then
    "$IMG" "$out" \( "$LOGO" -resize 175x -background none -gravity center -extent 210x210 \) \
      -gravity northwest -geometry +1045+215 -compose over -composite -quality 92 "$out"
  fi
}

portrait() {
  out=$1; bg1=$2; bg2=$3; body=$4; rim=$5
  "$IMG" -size 1600x1200 gradient:"$bg1-$bg2" \
    -fill 'rgba(255,235,200,0.30)' -draw 'circle 1230,250 1230,70' -blur 0x55 \
    -fill "$body" -draw 'ellipse 800,560 210,245 0,360' \
    -fill "$body" -draw "path 'M 330,1200 C 360,930 560,805 800,805 C 1040,805 1240,930 1270,1200 Z'" \
    -stroke "$rim" -strokewidth 5 -fill none -draw "path 'M 610,360 C 552,480 552,630 618,755'" \
    -stroke "$rim" -strokewidth 3 -draw "path 'M 662,388 C 616,498 616,625 668,740'" \
    \( -size 1600x1200 plasma:'#ffffff-#000000' -blur 0x5 \) -compose soft-light -define compose:args=11 -composite \
    +noise Gaussian -attenuate 0.02 -quality 92 "$out"
}

abstract() {
  out=$1; c1=$2; c2=$3; c3=$4
  "$IMG" -size 1600x1200 plasma:"$c1-$c2" -blur 0x5 -motion-blur 0x18+45 \
    -fill "$c3" -draw 'ellipse 1100,400 300,220 0,360' -blur 0x30 \
    +noise Gaussian -attenuate 0.03 -quality 92 "$out"
}

# T-Watch: night and low-light scenes
landscape "$STAGE/Pictures/T-Watch/01.jpg" '#0b1f33' '#7aa6c2' '#2b4a63' '#35543f' '#1d3527' '#5f8ea8' '#f4d49a'
landscape "$STAGE/Pictures/T-Watch/02.jpg" '#1a2036' '#c98d5a' '#3a3f63' '#4b5a4a' '#2a3527' '#6b8fb0' '#ffd98a'
landscape "$STAGE/Pictures/T-Watch/03.jpg" '#0f2438' '#9fc3d8' '#2d4f6b' '#3d5f52' '#223a2c' '#7fa3b8' '#ffe8b0'
landscape "$STAGE/Pictures/T-Watch/04.jpg" '#2a1f2e' '#e0a878' '#4a3f5a' '#4b5a4a' '#2a3527' '#8f6f8a' '#ffd98a'

# T-Deck: field and daylight scenes
landscape "$STAGE/Pictures/T-Deck/01.jpg" '#1d4a73' '#f0d09a' '#46657f' '#52765a' '#35543f' '#8fb7c9' '#ffe8b0'
landscape "$STAGE/Pictures/T-Deck/02.jpg" '#2b4a63' '#e8c9a0' '#3f5f7a' '#5f7a5a' '#2f4a38' '#7fa3b8' '#ffd98a'
landscape "$STAGE/Pictures/T-Deck/03.jpg" '#3a5a7a' '#f4d49a' '#4a6a8a' '#6b8a5a' '#3a553f' '#9fc3d8' '#fff2cf'
landscape "$STAGE/Pictures/T-Deck/04.jpg" '#1a2f4a' '#d9a978' '#334f6b' '#4b6a52' '#2a4030' '#6f93a8' '#ffd98a'

# Studio: painted abstracts
abstract "$STAGE/Pictures/Studio/01.jpg" '#2e3440' '#8fbcbb' '#d08770'
abstract "$STAGE/Pictures/Studio/02.jpg" '#3b4252' '#81a1c1' '#ebcb8b'
abstract "$STAGE/Pictures/Studio/03.jpg" '#1a1f27' '#b48ead' '#88c0d0'
abstract "$STAGE/Pictures/Studio/04.jpg" '#2e3440' '#a3be8c' '#5e81ac'

# Plein Air: the landscapes the album is named for
landscape "$STAGE/Pictures/Plein Air/01.jpg" '#1d4a73' '#f0d09a' '#46657f' '#52765a' '#35543f' '#8fb7c9' '#ffe8b0'
landscape "$STAGE/Pictures/Plein Air/02.jpg" '#2b4a63' '#e8c9a0' '#3f5f7a' '#5f7a5a' '#2f4a38' '#7fa3b8' '#ffd98a'
landscape "$STAGE/Pictures/Plein Air/03.jpg" '#3a5a7a' '#f4d49a' '#4a6a8a' '#6b8a5a' '#3a553f' '#9fc3d8' '#fff2cf'
landscape "$STAGE/Pictures/Plein Air/04.jpg" '#1a2f4a' '#d9a978' '#334f6b' '#4b6a52' '#2a4030' '#6f93a8' '#ffd98a'

# Portraits: silhouettes with a rim light, never a real person
portrait "$STAGE/Pictures/Portraits/01.jpg" '#cbb096' '#6f5148' '#2a2024' 'rgba(255,222,175,0.62)'
portrait "$STAGE/Pictures/Portraits/02.jpg" '#b9a0c0' '#5a4a6a' '#1f1a28' 'rgba(230,210,255,0.55)'
portrait "$STAGE/Pictures/Portraits/03.jpg" '#a8b8b0' '#4a5a52' '#1a2420' 'rgba(220,255,235,0.50)'
portrait "$STAGE/Pictures/Portraits/04.jpg" '#c9a88a' '#7a3f38' '#241818' 'rgba(255,190,150,0.60)'

# The Marker canvas: a 16:9 landscape with the JawnOS mark as the sun, so the
# capture can drop it onto the drawing surface.
landscape "$STAGE/Pictures/marker-landscape.jpg" '#1d4a73' '#f0d09a' '#46657f' '#52765a' '#35543f' '#8fb7c9' '#fff2cf' 1
"$IMG" "$STAGE/Pictures/marker-landscape.jpg" -crop 1600x900+0+150 +repage -quality 92 "$STAGE/Pictures/marker-landscape.jpg"

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
