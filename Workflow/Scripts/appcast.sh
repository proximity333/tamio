#!/bin/bash

# Writes the Sparkle appcast for one release: the feed the Mac app reads
# (SUFeedURL, the latest release's appcast.xml on GitHub) to learn of a new
# version. The disk image is signed with the release's EdDSA key, whose public
# half is SUPublicEDKey in the app's Info.plist.
#
# Usage: bash Workflow/Scripts/appcast.sh <Tamio-x.y.z.dmg> <tag> > appcast.xml
#
# The key is read from SPARKLE_KEY_FILE (a file holding the private key, as
# the SPARKLE_PRIVATE_KEY secret does). With no key given, the appcast lists
# the update without the EdDSA signature: Sparkle running in installed copies
# refuses such an update, but the release and its notes still stand.
#
# The update window shows the version's notes: its section of CHANGELOG.md
# (release-notes.sh) as HTML, which Sparkle shows in a web view. cmark, the
# reference CommonMark renderer, makes it, so the notes read as they do on
# GitHub: headings, bold leads, and bullets that wrap as one item.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="$1"
TAG="$2"
REPO="${GITHUB_REPOSITORY:-missuo/tamio}"
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-}"

bash "$ROOT_DIR/Workflow/Scripts/sparkle.sh" >&2

# The version is the app's, read from inside the image.
mount="$(mktemp -d)"
hdiutil attach "$IMAGE" -nobrowse -readonly -mountpoint "$mount" >/dev/null
plist="$mount/Tamio.app/Contents/Info.plist"
short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || echo 14.0)"
hdiutil detach "$mount" -quiet
rmdir "$mount"

# Prints: sparkle:edSignature="…" length="…" — or nothing, when no key was
# given and the update is listed unsigned.
attributes=""
if [[ -n "$SPARKLE_KEY_FILE" ]]; then
    attributes="$("$ROOT_DIR/External/Sparkle/bin/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$IMAGE")"
    [[ "$attributes" == *edSignature=* ]] || { printf 'sign_update failed.\n' >&2; exit 1; }
else
    printf 'No SPARKLE_KEY_FILE: listing the update without an EdDSA signature.\n' >&2
fi

command -v cmark >/dev/null || brew install cmark >&2
notes="$(bash "$ROOT_DIR/Workflow/Scripts/release-notes.sh" "$short" | cmark)"
# Nothing in the notes may close the CDATA section they go in.
notes="${notes//]]>/]] >}"

name="$(basename "$IMAGE")"
date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tamio</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Tamio $short</title>
      <pubDate>$date</pubDate>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$short</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <description><![CDATA[$notes]]></description>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$name" type="application/octet-stream" $attributes />
    </item>
  </channel>
</rss>
XML
