#!/bin/zsh
# Builds Tern.app into ./build. Flags:
#   --install   copy to ~/Applications and relaunch
#   --debug     debug build (faster compile)
# Signs with $TERN_SIGN_IDENTITY, else the first "Apple Development" identity, else ad-hoc.
# A stable identity keeps Keychain access to saved Google tokens across rebuilds.
# The version comes from version.env. TERN_RELEASE=1 (set by scripts/release.sh) adds the update feed and
# Sparkle's public key to Info.plist (TERN_FEED_URL points it at another appcast, for testing); without them the
# app never looks for updates.
set -euo pipefail
cd "${0:A:h}"
source ./version.env

CONFIG=release
[[ " $* " == *" --debug "* ]] && CONFIG=debug

# --disable-keychain: SwiftPM looks for download credentials in the Keychain, which can stall on an access prompt.
swift build --disable-keychain -c $CONFIG --arch arm64 --product Tern
BINDIR=$(swift build --disable-keychain -c $CONFIG --arch arm64 --show-bin-path)
BIN=$BINDIR/Tern

APP=build/Tern.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APP/Contents/Frameworks
cp $BIN $APP/Contents/MacOS/Tern
# Sparkle (auto-update) is a dynamic framework; ditto keeps its symlinks.
ditto $BINDIR/Sparkle.framework $APP/Contents/Frameworks/Sparkle.framework
install_name_tool -add_rpath @executable_path/../Frameworks $APP/Contents/MacOS/Tern 2>/dev/null || true
if [[ -d Resources/Fonts ]] && ls Resources/Fonts/*(N) >/dev/null 2>&1 && [[ -n "$(ls Resources/Fonts)" ]]; then
  mkdir -p $APP/Contents/Resources/Fonts
  cp Resources/Fonts/* $APP/Contents/Resources/Fonts/
fi
if [[ -d Resources/Web ]]; then
  cp -R Resources/Web $APP/Contents/Resources/Web
fi
if [[ -d Resources/Licenses ]]; then
  cp -R Resources/Licenses $APP/Contents/Resources/Licenses
fi

if [[ -f scripts/icon.swift && ( ! -f build/AppIcon.icns || scripts/icon.swift -nt build/AppIcon.icns ) ]]; then
  ICONSET=build/AppIcon.iconset
  mkdir -p $ICONSET
  swift scripts/icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $ICONSET -o build/AppIcon.icns
fi
[[ -f build/AppIcon.icns ]] && cp build/AppIcon.icns $APP/Contents/Resources/AppIcon.icns

UPDATES=""
if [[ ${TERN_RELEASE:-} == 1 ]]; then
  # Sparkle reads these: the appcast of the newest release, the EdDSA public key that update archives must be
  # signed with (the private key stays in ~/.private_keys, see scripts/release.sh), daily checks without asking,
  # background downloads on by default (Settings → Advanced), and the signature checked before unpacking.
  UPDATES="
  <key>SUFeedURL</key><string>${TERN_FEED_URL:-https://github.com/dhruvalgolakiya/tern-releases/releases/latest/download/appcast.xml}</string>
  <key>SUPublicEDKey</key><string>tCqPvPoar00JutjK+E420HOC1e6vWreGA8qR2Q/hB/8=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>"
fi

cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tern</string>
  <key>CFBundleDisplayName</key><string>Tern</string>
  <key>CFBundleIdentifier</key><string>dev.tern.mail</string>
  <key>CFBundleExecutable</key><string>Tern</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$TERN_VERSION</string>
  <key>CFBundleVersion</key><string>$TERN_BUILD</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Mail link</string>
    <key>CFBundleURLSchemes</key><array><string>mailto</string></array>
  </dict></array>$UPDATES
</dict>
</plist>
PLIST

IDENTITY=${TERN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)"/\1/' || true)}
# Inside out: Sparkle's helpers, the framework, then the app (release.sh signs again with its Developer ID).
SPARKLE=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
for xpc in $SPARKLE/XPCServices/*.xpc(N); do
  codesign --force --sign "${IDENTITY:--}" --preserve-metadata=entitlements $xpc >/dev/null 2>&1
done
codesign --force --sign "${IDENTITY:--}" $SPARKLE/Autoupdate $SPARKLE/Updater.app $APP/Contents/Frameworks/Sparkle.framework >/dev/null 2>&1
codesign --force --sign "${IDENTITY:--}" $APP >/dev/null 2>&1
echo "Built $APP ($(du -sh $APP | cut -f1)), signed: ${IDENTITY:-ad-hoc}"

if [[ " $* " == *" --install "* ]]; then
  mkdir -p ~/Applications
  pkill -x Tern 2>/dev/null || true
  rm -rf ~/Applications/Tern.app
  cp -R $APP ~/Applications/
  open ~/Applications/Tern.app
  echo "Installed ~/Applications/Tern.app"
fi
