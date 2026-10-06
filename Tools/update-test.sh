#!/bin/zsh
# Checks that saved passwords survive a real Sparkle update between two signed Release builds.
#
#   Tools/update-test.sh [logins]      (default 500)
#
# It never touches the installed iSmith or its data: the builds use their own bundle id
# (com.scottsmith.ismith.updatetest), so their own Keychain items and defaults, and a scratch
# data folder under build/update-test. They are signed as releases are (archive, then export for
# Developer ID; not notarized, so they only run on this Mac) and compiled with ISMITH_UPDATE_TEST,
# which adds App/UpdateTestHook.swift: it seeds logins and writes a report of what the store holds.
#
# 1. Builds A (9.0.0) and B (9.0.1), a throwaway EdDSA key, and a local appcast offering B.
# 2. Launches A: it seeds the logins and its updater downloads B in the background.
# 3. Quits A: Sparkle's installer replaces the app in place. Launches B.
# 4. Passes when B opens the same store with every login readable.
set -euo pipefail
setopt null_glob
LOGINS="${1:-500}"
ROOT="${0:A:h:h}"
cd "$ROOT"
OUT="$ROOT/build/update-test"
ID=com.scottsmith.ismith.updatetest
PORT=8799
step() { print -P "%B==> $1%b" }

rm -rf "$OUT"; mkdir -p "$OUT/feed" "$OUT/data" "$OUT/reports" "$OUT/install"

step "Throwaway update key and test project"
openssl genpkey -algorithm ed25519 -out "$OUT/ed.pem"
openssl pkey -in "$OUT/ed.pem" -outform DER | tail -c 32 | base64 > "$OUT/ed-priv.b64"
PUB="$(openssl pkey -in "$OUT/ed.pem" -pubout -outform DER | tail -c 32 | base64)"
sed -e "s|PRODUCT_BUNDLE_IDENTIFIER: com.scottsmith.ismith$|PRODUCT_BUNDLE_IDENTIFIER: $ID|" \
    -e "s|SUFeedURL: .*|SUFeedURL: http://127.0.0.1:$PORT/appcast.xml|" \
    -e "s|SUPublicEDKey: .*|SUPublicEDKey: $PUB|" project.yml > "$OUT/project.yml"
cp "$OUT/project.yml" project-updatetest.yml
restore() {
  rm -f project-updatetest.yml
  xcodegen generate -q
  [[ -n "${SERVER:-}" ]] && kill "$SERVER" 2>/dev/null || true
}
trap restore EXIT
xcodegen generate -q --spec project-updatetest.yml

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>destination</key><string>export</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>232A77467G</string>
</dict></plist>
EOF
for v in A:9.0.0:9000 B:9.0.1:9001; do
  NAME=${v%%:*}; REST=${v#*:}; VERSION=${REST%%:*}; BUILD=${REST#*:}
  step "Archiving and exporting $NAME ($VERSION) for Developer ID"
  xcodebuild -project iSmith.xcodeproj -scheme iSmith -configuration Release -derivedDataPath "$OUT/dd" \
    -archivePath "$OUT/$NAME.xcarchive" MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ISMITH_UPDATE_TEST' archive > "$OUT/archive-$NAME.log" 2>&1 \
    || { tail -20 "$OUT/archive-$NAME.log"; exit 1; }
  xcodebuild -exportArchive -archivePath "$OUT/$NAME.xcarchive" -exportPath "$OUT/$NAME" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates > "$OUT/export-$NAME.log" 2>&1 \
    || { tail -20 "$OUT/export-$NAME.log"; exit 1; }
  codesign -dvv "$OUT/$NAME/iSmith.app" 2>&1 | grep -E "^Authority=Developer ID Application" >/dev/null \
    || { echo "$NAME isn't signed with Developer ID"; exit 1; }
done

step "Appcast offering B"
ditto -c -k --sequesterRsrc --keepParent "$OUT/B/iSmith.app" "$OUT/feed/iSmith-9.0.1.zip"
SIG="$("$OUT/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" --ed-key-file "$OUT/ed-priv.b64" "$OUT/feed/iSmith-9.0.1.zip")"
cat > "$OUT/feed/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>update test</title>
<item><title>9.0.1</title><sparkle:version>9001</sparkle:version><sparkle:shortVersionString>9.0.1</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><pubDate>Tue, 06 Oct 2026 12:00:00 +0000</pubDate>
<enclosure url="http://127.0.0.1:$PORT/iSmith-9.0.1.zip" $SIG type="application/octet-stream"/></item>
</channel></rss>
EOF
lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null && { echo "Port $PORT is in use."; exit 1; }
(cd "$OUT/feed" && exec python3 -m http.server $PORT --bind 127.0.0.1 >"$OUT/http.log" 2>&1) &
SERVER=$!

step "Fresh test Keychain items and settings"
for svc in $ID.passwords-key $ID.vault-key; do
  while security delete-generic-password -s $svc >/dev/null 2>&1; do :; done
done
defaults delete $ID >/dev/null 2>&1 || true
defaults write $ID UTDataDir "$OUT/data"
defaults write $ID UTReportDir "$OUT/reports"
defaults write $ID UTSeed -int "$LOGINS"
defaults write $ID UTCheckNow -bool YES
defaults write $ID SUEnableAutomaticChecks -bool YES
defaults write $ID SUAutomaticallyUpdate -bool YES
touch "$OUT/data/brave-import-offered"
ditto "$OUT/A/iSmith.app" "$OUT/install/iSmith.app"
BINARY="$OUT/install/iSmith.app/Contents/MacOS/iSmith"

# The newest report of a version, or nothing (null_glob: no match is an empty list).
report() { local found=("$OUT"/reports/report-$1-*.json(Om)); print -r -- "${found[-1]:-}" }
waitfor() { for _ in {1..120}; do eval "$1" && return 0; sleep 1; done; echo "Timed out: $2"; exit 1 }

step "A: seed $LOGINS logins, download B"
open -n "$OUT/install/iSmith.app"
waitfor '[[ -n "$(report 9.0.0)" ]]' "A's report"
waitfor 'grep -q "GET /iSmith-9.0.1.zip" "$OUT/http.log"' "B's download"
sleep 3
step "Quitting A: Sparkle installs B"
defaults write $ID UTCheckNow -bool NO
pkill -TERM -f "^$BINARY" || true
waitfor '[[ "$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$OUT/install/iSmith.app/Contents/Info.plist")" == 9.0.1 ]]' "the install of B"
codesign --verify --deep --strict "$OUT/install/iSmith.app"

step "B: open the same store"
waitfor '! pgrep -f "^$BINARY" >/dev/null' "A to quit"
open -n "$OUT/install/iSmith.app"
waitfor '[[ -n "$(report 9.0.1)" ]]' "B's report"
pkill -TERM -f "^$BINARY" || true
python3 - "$(report 9.0.0)" "$(report 9.0.1)" "$LOGINS" <<'EOF'
import json, sys
a, b, n = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), int(sys.argv[3])
print("A:", a); print("B:", b)
ok = (a["readable"] == n and b["storeOpened"] and b["movedAside"] is None and b["problem"] is None
      and b["readable"] == n and b["unreadable"] == 0 and b["matchesSite0"] == 1)
print("PASS: every login survived the update" if ok else "FAIL")
sys.exit(0 if ok else 1)
EOF
