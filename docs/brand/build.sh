#!/usr/bin/env bash
# Regenerate the Hamaca icon set: SVG masters (make_icons.py), then every PNG export.
# Needs rsvg-convert and ImageMagick (`brew install librsvg imagemagick`).
set -euo pipefail
cd "$(dirname "$0")"
python3 make_icons.py

S=svg
E=exports
rm -rf "$E"
mkdir -p "$E"/{ios,android,web,brand}

png() { rsvg-convert -w "$2" -h "$2" "$S/$1.svg" -o "$3"; }
opaque() { png "$1" "$2" "$3"; magick "$3" -background "$4" -alpha remove -alpha off "$3"; }

# iOS: one 1024 opaque master (Xcode 14+ single-size), plus iOS 18 dark and tinted.
opaque app-icon 1024 "$E/ios/AppIcon-1024.png" "#FFFFFF"
png app-icon-dark 1024 "$E/ios/AppIcon-1024-dark.png"
opaque app-icon-tinted 1024 "$E/ios/AppIcon-1024-tinted.png" "#000000"

# Android: adaptive layers per density (108dp), legacy launcher icons, Play Store.
for d in mdpi:108:48 hdpi:162:72 xhdpi:216:96 xxhdpi:324:144 xxxhdpi:432:192; do
  IFS=: read -r name adaptive legacy <<<"$d"
  mkdir -p "$E/android/mipmap-$name"
  png android-foreground "$adaptive" "$E/android/mipmap-$name/ic_launcher_foreground.png"
  png android-background "$adaptive" "$E/android/mipmap-$name/ic_launcher_background.png"
  png android-monochrome "$adaptive" "$E/android/mipmap-$name/ic_launcher_monochrome.png"
  png favicon "$legacy" "$E/android/mipmap-$name/ic_launcher.png"
done
opaque app-icon 512 "$E/android/play-store-512.png" "#FFFFFF"

# Web: SVG favicon, PNG favicons (heavy-cord version), .ico, touch + PWA icons, share card.
cp "$S/favicon.svg" "$E/web/favicon.svg"
for n in 16 32 48; do png favicon "$n" "$E/web/favicon-$n.png"; done
magick "$E/web/favicon-16.png" "$E/web/favicon-32.png" "$E/web/favicon-48.png" "$E/web/favicon.ico"
opaque app-icon 180 "$E/web/apple-touch-icon.png" "#FFFFFF"
png app-icon 192 "$E/web/icon-192.png"
png app-icon 512 "$E/web/icon-512.png"
png icon-maskable 512 "$E/web/icon-maskable-512.png"
rsvg-convert "$S/og-image.svg" -o "$E/web/og-image.png"

# Brand marks on transparency.
png mark-color 1024 "$E/brand/mark-color-1024.png"
png mark-white 1024 "$E/brand/mark-white-1024.png"
png mark-mono 1024 "$E/brand/mark-mono-1024.png"

echo "Exported $(find "$E" -type f | wc -l | tr -d ' ') files to docs/brand/$E"
