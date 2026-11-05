#!/bin/zsh
# Build, sign and install Frontier Map on a plugged-in iPhone. Rerun whenever the free 7-day signing expires.
# Needs: Xcode signed in to your Apple ID, and Config/Secrets.xcconfig (see Secrets.example.xcconfig).
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

grep -q '^DEVELOPMENT_TEAM *= *[A-Z0-9]' Config/Secrets.xcconfig 2>/dev/null ||
  { echo "Config/Secrets.xcconfig needs MAPTILER_KEY and DEVELOPMENT_TEAM (see Secrets.example.xcconfig)."; exit 1; }

# Voice model and sherpa-onnx: same as the "Fetch Kokoro" step in .github/workflows/ios.yml.
if [[ ! -d Kokoro || ! -d Frameworks/SherpaOnnxC.xcframework ]]; then
  echo "Fetching voice model (~170 MB, first time only)..."
  base=https://github.com/k2-fsa/sherpa-onnx/releases/download
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/sherpa.zip" $base/xcframework/sherpa-onnx-v1.13.8-ios-shared-onnxruntime-static.xcframework.zip
  rm -rf Frameworks && mkdir -p Frameworks && unzip -q "$tmp/sherpa.zip" -d Frameworks
  curl -fsSL $base/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2 | tar xj -C "$tmp"
  rm -rf Kokoro && mkdir Kokoro
  (cd "$tmp/kokoro-int8-multi-lang-v1_0" && mv model.int8.onnx voices.bin tokens.txt lexicon-us-en.txt espeak-ng-data LICENSE "$OLDPWD/Kokoro/")
  python3 -I scripts/blend_voice.py Kokoro/voices.bin 53 17:0.7 26:0.3
  rm -rf "$tmp"
fi

# First connected, available iPhone.
json=$(mktemp)
xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1
udid=$(python3 -I -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") == "iOS" and hw.get("reality") == "physical" and d.get("connectionProperties", {}).get("tunnelState") != "unavailable":
        print(hw["udid"]); break
' "$json")
rm -f "$json"
[[ -n "$udid" ]] || { echo "No iPhone found. Plug it in, unlock it and tap Trust."; exit 1; }
echo "Installing on $udid"

which xcodegen >/dev/null || brew install xcodegen
xcodegen generate --quiet
echo "Building (a few minutes)..."
log=build/install.log; mkdir -p build
xcodebuild -project FrontierMap.xcodeproj -scheme FrontierMap -configuration Release \
  -destination "id=$udid" -derivedDataPath build -allowProvisioningUpdates build >"$log" 2>&1 ||
  { grep -E "error:" "$log" | sort -u | head -20
    grep -q -i -E "bundle identifier|not available|provisioning profile" "$log" &&
      echo "Signing problem: set FRONTIER_BUNDLE_ID in Config/Secrets.xcconfig to an ID of your own, e.g. com.yourname.frontiermap."
    echo "Build failed. Full log: $PWD/$log"; exit 1; }
app=build/Build/Products/Release-iphoneos/FrontierMap.app
bundle_id=$(plutil -extract CFBundleIdentifier raw "$app/Info.plist")

xcrun devicectl device install app --device "$udid" "$app" 2>&1 | grep -v "Auto-pair failed" | grep -E "installed|error" || true
launch() { xcrun devicectl device process launch --device "$udid" "$bundle_id" >/dev/null 2>&1; }
if launch || { sleep 3; launch; }; then
  echo "Done: Frontier Map is open on your iPhone. Signing lasts until $(date -v+7d '+%a %b %d')."
else
  echo "Installed (signing lasts until $(date -v+7d '+%a %b %d')), but it didn't open by itself. Unlock the phone and tap it."
  echo "If iOS says the developer isn't trusted: Settings › General › VPN & Device Management › trust your Apple ID."
fi
