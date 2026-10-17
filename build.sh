#!/bin/zsh
# Builds Tern.app into ./build. Flags:
#   --install   copy to ~/Applications and relaunch
#   --debug     debug build (faster compile)
# Signs with $TERN_SIGN_IDENTITY, else the first "Apple Development" identity, else ad-hoc.
# A stable identity keeps Keychain access to saved Google tokens across rebuilds.
set -euo pipefail
cd "${0:A:h}"

CONFIG=release
[[ " $* " == *" --debug "* ]] && CONFIG=debug

swift build -c $CONFIG --arch arm64 --product Tern
BIN=$(swift build -c $CONFIG --arch arm64 --show-bin-path)/Tern

APP=build/Tern.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Tern
if [[ -d Resources/Fonts ]] && ls Resources/Fonts/*(N) >/dev/null 2>&1 && [[ -n "$(ls Resources/Fonts)" ]]; then
  mkdir -p $APP/Contents/Resources/Fonts
  cp Resources/Fonts/* $APP/Contents/Resources/Fonts/
fi
if [[ -d Resources/Web ]]; then
  cp -R Resources/Web $APP/Contents/Resources/Web
fi

if [[ -f scripts/icon.swift && ! -f build/AppIcon.icns ]]; then
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
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Mail link</string>
    <key>CFBundleURLSchemes</key><array><string>mailto</string></array>
  </dict></array>
</dict>
</plist>
PLIST

IDENTITY=${TERN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)"/\1/' || true)}
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
