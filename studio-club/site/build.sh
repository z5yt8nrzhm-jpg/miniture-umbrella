#!/usr/bin/env bash
# Assembles the public website into ./out: a landing page, the links page and
# studio desk, the members club preview (demo mode, made-up members) and the
# Food Court FM radio. Nothing private and no keys go in.
#
#   site/build.sh                    site served from the top of a domain
#   site/build.sh /gilbert-flex-site   site served from a GitHub Pages project path
#
# Needs Flutter on the PATH, and the radio branch fetched (origin/claude/food-court-fm).
set -euo pipefail
PREFIX="${1:-}"                       # "" or "/some-path"
cd "$(dirname "$0")/.."
OUT="site/out"
rm -rf "$OUT"; mkdir -p "$OUT/links/vendor" "$OUT/radio"

cp site/index.html "$OUT/index.html"
cp schedule/index.html schedule/studio.html "$OUT/links/"
cp schedule/vendor/qrcode.js "$OUT/links/vendor/"
git show origin/claude/food-court-fm:food-court-fm/index.html > "$OUT/radio/index.html"
git show origin/claude/food-court-fm:food-court-fm/app.jsx    > "$OUT/radio/app.jsx"

# The club preview in demo mode: no SUPABASE_URL / SUPABASE_KEY, so it only ever shows made-up data.
flutter build web --release --no-web-resources-cdn --pwa-strategy=none --base-href "$PREFIX/club/" --output "$OUT/club"
# Keep only the renderers phones and desktop Chrome use.
rm -rf "$OUT"/club/canvaskit/skwasm* "$OUT"/club/canvaskit/wimp* "$OUT"/club/canvaskit/webparagraph "$OUT"/club/canvaskit/*.symbols "$OUT"/club/canvaskit/chromium/*.symbols
touch "$OUT/.nojekyll"
echo "built $OUT ($(du -sh "$OUT" | cut -f1))"
