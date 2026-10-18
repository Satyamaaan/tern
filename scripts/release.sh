#!/bin/zsh
# Builds a release of Tern from version.env:
#   build/Tern-<version>.dmg   the download: a styled install window (drag Tern to Applications)
#   build/Tern-<version>.zip   the update Sparkle downloads, EdDSA-signed
#   build/appcast.xml          the feed listing it, with release-notes/<version>.md as "What's new"
# Tern.app is signed with a Developer ID, hardened, notarized by Apple and stapled, so it opens on any Mac without a
# Gatekeeper warning, even offline. scripts/publish.sh <version> then uploads the three files. Needs:
#   a "Developer ID Application" certificate, in the keychain or as TERN_SIGN_P12 (+ TERN_SIGN_P12_PASSWORD), which
#     is imported into a throwaway keychain (codesign can stall on the login keychain's access prompt)
#   a notarytool keychain profile named TERN_NOTARY_PROFILE (default "tern"), made once with
#     xcrun notarytool store-credentials tern --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer id>
#   Sparkle's EdDSA private key as a file, ~/.private_keys/tern-sparkle-ed25519 or TERN_SPARKLE_KEY (made once with
#     Sparkle's generate_keys -x; never in the Keychain or the repo). Its public key is in build.sh.
#   release-notes/<version>.md
# TERN_SIGN_IDENTITY picks the certificate when there are several. The DMG is built by dmgbuild (MIT), installed
# on first run into a pinned virtualenv under build/.
set -euo pipefail
cd "${0:A:h}/.."
source ./version.env

VERSION=$TERN_VERSION
BUILD=$TERN_BUILD
PROFILE=${TERN_NOTARY_PROFILE:-tern}
SPARKLE_KEY=${TERN_SPARKLE_KEY:-$HOME/.private_keys/tern-sparkle-ed25519}
NOTES=release-notes/$VERSION.md
DOWNLOADS=https://github.com/dhruvalgolakiya/tern-releases/releases/download/v$VERSION
DMGBUILD=(dmgbuild==1.6.7 ds-store==1.3.3 mac-alias==2.2.3)

# Everything that can be missing is checked before the slow parts.
[[ -f $NOTES ]] || { echo "Write $NOTES first: the update window shows it as \"What's new\"." >&2; exit 1; }
[[ -f $SPARKLE_KEY ]] || { echo "No Sparkle signing key at $SPARKLE_KEY." >&2; exit 1; }
swift package --disable-keychain resolve >/dev/null
SIGN_UPDATE=(.build/artifacts/sparkle/Sparkle/bin/sign_update(N))
[[ -n ${SIGN_UPDATE:-} ]] || { echo "Sparkle's sign_update is missing; run swift build once." >&2; exit 1; }

keychain=()
if [[ -n ${TERN_SIGN_P12:-} ]]; then
  dir=$(mktemp -d)
  KEYCHAIN=$dir/sign.keychain-db
  pass=$(uuidgen)
  searched=("${(@f)$(security list-keychains -d user | tr -d ' "')}")
  cleanup() {
    security list-keychains -d user -s $searched
    security delete-keychain $KEYCHAIN 2>/dev/null
    rm -rf $dir
  }
  trap cleanup EXIT
  trap 'exit 1' INT TERM
  security create-keychain -p "$pass" $KEYCHAIN
  security set-keychain-settings -lut 3600 $KEYCHAIN
  security unlock-keychain -p "$pass" $KEYCHAIN
  security import $TERN_SIGN_P12 -k $KEYCHAIN -P "${TERN_SIGN_P12_PASSWORD:-}" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" $KEYCHAIN >/dev/null
  # codesign stalls on a keychain that isn't on the search list, even with --keychain.
  security list-keychains -d user -s $KEYCHAIN $searched
  keychain=(--keychain $KEYCHAIN)
fi
# The certificate's hash, so a copy of the same certificate in another keychain can't make the name ambiguous.
IDENTITY=$(security find-identity -v -p codesigning ${KEYCHAIN:-} \
  | grep "\"${TERN_SIGN_IDENTITY:-Developer ID Application}" | head -1 | awk '{print $2}')
[[ -n $IDENTITY ]] || { echo "No Developer ID Application certificate found." >&2; exit 1; }

notarize() {
  local out id
  out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || true
  print -r -- "$out" | grep -E '^ *(id|status):' | sort -u
  if ! print -r -- "$out" | grep -q 'status: Accepted'; then
    id=$(print -r -- "$out" | awk '/^ *id:/ {print $2; exit}')
    [[ -n $id ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE"
    print -r -- "$out" >&2
    exit 1
  fi
}

sign() {
  codesign --force --options runtime --timestamp --sign $IDENTITY $keychain "$@"
}

# Ad hoc for now (build.sh would otherwise reach for TERN_SIGN_IDENTITY in the login keychain); signed for real below.
TERN_RELEASE=1 TERN_SIGN_IDENTITY=- ./build.sh
APP=build/Tern.app
[[ $(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' $APP/Contents/Info.plist 2>/dev/null) == https://* ]] \
  || { echo "build.sh didn't add the update feed to Info.plist." >&2; exit 1; }

# Inside out, never --deep: Sparkle's XPC services (the downloader keeps its network entitlement), its installer
# and updater apps, the framework, then Tern.
SPARKLE=$APP/Contents/Frameworks/Sparkle.framework
for xpc in $SPARKLE/Versions/B/XPCServices/*.xpc(N); do sign --preserve-metadata=entitlements $xpc; done
sign $SPARKLE/Versions/B/Autoupdate
sign $SPARKLE/Versions/B/Updater.app
sign $SPARKLE
sign $APP
codesign --verify --deep --strict --verbose=1 $APP

# The app on its own first, so its ticket can be stapled to it before it goes in the update and the disk image.
ditto -c -k --keepParent $APP build/Tern-notarize.zip
notarize build/Tern-notarize.zip
rm build/Tern-notarize.zip
xcrun stapler staple $APP

# The update: the stapled app, zipped and signed with the EdDSA key, and the appcast that lists it.
ZIP=build/Tern-$VERSION.zip
rm -f $ZIP
ditto -c -k --sequesterRsrc --keepParent $APP $ZIP
SIGNATURE=$($SIGN_UPDATE[1] --ed-key-file $SPARKLE_KEY -p $ZIP)
$SIGN_UPDATE[1] --verify --ed-key-file $SPARKLE_KEY $ZIP "$SIGNATURE"
swift scripts/appcast.swift --version $VERSION --build $BUILD --notes $NOTES --url $DOWNLOADS/Tern-$VERSION.zip \
  --length $(stat -f %z $ZIP) --signature "$SIGNATURE" --min-system 15.0 --out build/appcast.xml

# The disk image: Tern and Applications over the drawn background, laid out by dmgbuild (no Finder scripting).
VENV=build/dmgbuild-venv
if [[ ! -x $VENV/bin/dmgbuild ]]; then
  python3 -m venv $VENV
  $VENV/bin/pip install --quiet --disable-pip-version-check $DMGBUILD
fi
swift scripts/dmg-background.swift build/dmg
tiffutil -cathidpicheck build/dmg/background.png build/dmg/background@2x.png -out build/dmg/background.tiff 2>/dev/null
DMG=build/Tern-$VERSION.dmg
rm -f $DMG
$VENV/bin/dmgbuild -s scripts/dmg-settings.py -D app=$APP -D background=build/dmg/background.tiff \
  -D icon=build/AppIcon.icns Tern $DMG >/dev/null
codesign --force --timestamp --sign $IDENTITY $keychain $DMG
notarize $DMG
xcrun stapler staple $DMG

spctl --assess --type execute --verbose=2 $APP
spctl --assess --type open --context context:primary-signature --verbose=2 $DMG
for file in $DMG $ZIP build/appcast.xml; do
  echo "Built $file ($(du -h $file | cut -f1)) sha256 $(shasum -a 256 $file | cut -d' ' -f1)"
done
echo "Next: scripts/publish.sh $VERSION"
