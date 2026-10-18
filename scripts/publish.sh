#!/bin/zsh
# Uploads a release built by scripts/release.sh to GitHub: build/Tern-<version>.dmg, build/Tern-<version>.zip and
# build/appcast.xml go to the release v<version> in dhruvalgolakiya/tern-releases (TERN_RELEASES_REPO), created as a
# draft and published once every file is up, so Sparkle never reads an appcast whose update isn't there yet. The
# installed apps read .../releases/latest/download/appcast.xml, which follows the newest published release.
# Uses gh, signed in or with GH_TOKEN. Run: scripts/publish.sh 0.2.0
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${1:?usage: scripts/publish.sh <version>}
REPO=${TERN_RELEASES_REPO:-dhruvalgolakiya/tern-releases}
TAG=v$VERSION
FILES=(build/Tern-$VERSION.dmg build/Tern-$VERSION.zip build/appcast.xml)
NOTES=release-notes/$VERSION.md

for file in $FILES $NOTES; do
  [[ -f $file ]] || { echo "Missing $file; run scripts/release.sh first." >&2; exit 1; }
done
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" build/appcast.xml \
  || { echo "build/appcast.xml isn't for $VERSION." >&2; exit 1; }
grep -q "/download/$TAG/Tern-$VERSION.zip" build/appcast.xml \
  || { echo "build/appcast.xml doesn't point at $TAG/Tern-$VERSION.zip." >&2; exit 1; }

if gh release view $TAG --repo $REPO >/dev/null 2>&1; then
  gh release upload $TAG $FILES --repo $REPO --clobber
else
  gh release create $TAG $FILES --repo $REPO --draft --title "Tern $VERSION" --notes-file $NOTES
  gh release edit $TAG --repo $REPO --draft=false --latest
fi
echo "Published https://github.com/$REPO/releases/tag/$TAG"
