#!/bin/zsh
# Builds build/Tern-<version>.dmg: Tern.app signed with a Developer ID, hardened, notarized by Apple and stapled, so
# it opens on any Mac without a Gatekeeper warning, even offline after it is dragged out of the disk image. Needs:
#   a "Developer ID Application" certificate, in the keychain or as TERN_SIGN_P12 (+ TERN_SIGN_P12_PASSWORD), which
#     is imported into a throwaway keychain (codesign can stall on the login keychain's access prompt)
#   a notarytool keychain profile named TERN_NOTARY_PROFILE (default "tern"), made once with
#     xcrun notarytool store-credentials tern --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer id>
# TERN_SIGN_IDENTITY picks the certificate when there are several.
set -euo pipefail
cd "${0:A:h}/.."

PROFILE=${TERN_NOTARY_PROFILE:-tern}
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

# Ad hoc for now (build.sh would otherwise reach for TERN_SIGN_IDENTITY in the login keychain); signed for real below.
TERN_SIGN_IDENTITY=- ./build.sh
APP=build/Tern.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $APP/Contents/Info.plist)
codesign --force --options runtime --timestamp --sign $IDENTITY $keychain $APP
codesign --verify --strict --verbose=1 $APP

# The app on its own first, so its ticket can be stapled to it before it goes in the disk image.
ditto -c -k --keepParent $APP build/Tern-notarize.zip
notarize build/Tern-notarize.zip
rm build/Tern-notarize.zip
xcrun stapler staple $APP

stage=$(mktemp -d)
cp -R $APP $stage/
ln -s /Applications $stage/Applications
DMG=build/Tern-$VERSION.dmg
rm -f $DMG
hdiutil create -volname "Tern $VERSION" -srcfolder $stage -fs HFS+ -format ULFO -ov $DMG >/dev/null
rm -rf $stage
codesign --force --timestamp --sign $IDENTITY $keychain $DMG
notarize $DMG
xcrun stapler staple $DMG

spctl --assess --type execute --verbose=2 $APP
spctl --assess --type open --context context:primary-signature --verbose=2 $DMG
echo "Built $DMG ($(du -h $DMG | cut -f1)) sha256 $(shasum -a 256 $DMG | cut -d' ' -f1)"
