#!/bin/zsh
# Builds a signed installer package of __APP_NAME__ for the Mac App Store.
# Run it on a Mac with these in the keychain (Xcode > Settings > Accounts > Manage Certificates):
#   Apple Distribution: <name> (<TEAM_ID>)
#   3rd Party Mac Developer Installer: <name> (<TEAM_ID>)   (newer accounts: Mac Installer Distribution)
# and a Mac App Store provisioning profile for __BUNDLE_ID__ saved as AppStore/embedded.provisionprofile
# (developer.apple.com > Certificates, Identifiers & Profiles > Profiles).
#
# Usage: TEAM_ID=ABCDE12345 tools/appstore.sh             build and sign the .pkg
#        TEAM_ID=ABCDE12345 tools/appstore.sh --upload    also upload with an App Store Connect API key:
#            ASC_KEY_ID=... ASC_ISSUER_ID=... (key file in ~/.appstoreconnect/private_keys/AuthKey_<id>.p8)
# Without --upload, drag the .pkg into Apple's Transporter app.
# Output: ~/Library/Developer/__APP_NAME__/dist/__APP_NAME__.pkg
set -euo pipefail
here=${0:A:h:h}
name="__APP_NAME__"
bundle="__BUNDLE_ID__"
team=${TEAM_ID:?set TEAM_ID to your 10 character Apple team id}
profile="$here/AppStore/embedded.provisionprofile"
[[ -f "$profile" ]] || { echo "missing $profile: download the Mac App Store profile for $bundle"; exit 1; }
dist_id=${DIST_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Distribution: [^"]*"' | tr -d '"' || true)}
inst_id=${INSTALLER_IDENTITY:-$(security find-identity -v | grep -m1 -oE '"(3rd Party Mac Developer Installer|Mac Installer Distribution): [^"]*"' | tr -d '"' || true)}
[[ -n "$dist_id" ]] || { echo "no 'Apple Distribution' certificate in the keychain"; exit 1; }
[[ -n "$inst_id" ]] || { echo "no installer certificate ('3rd Party Mac Developer Installer' or 'Mac Installer Distribution')"; exit 1; }

scratch="$HOME/Library/Developer/$name/dist-build"
out="$HOME/Library/Developer/$name/dist"
rm -rf "$out"; mkdir -p "$out"

# Universal binary: macOS 26 still runs on some Intel Macs.
swift build -c release --arch arm64 --arch x86_64 --package-path "$here" --scratch-path "$scratch"
bin="$scratch/apple/Products/Release/$name"
[[ -x "$bin" ]] || { echo "build failed: no $bin"; exit 1; }

app="$out/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
# The App Store needs a build number higher than the last upload.
sed -e "s/__BUILD__/${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
if [[ -d "$here/Icon/AppIcon.icon" ]]; then
  [[ -f "$here/Resources/Assets.car" ]] || "$here/tools/make_icon.sh"
  cp -X "$here/Resources/Assets.car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
fi
cp -X "$here/AppStore/PrivacyInfo.xcprivacy" "$app/Contents/Resources/"
cp "$profile" "$app/Contents/embedded.provisionprofile"

# The signed entitlements must also name the team and app id, as in the profile.
ent="$out/signing.entitlements"
cp "$here/AppStore/App.entitlements" "$ent"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $team.$bundle" "$ent"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $team" "$ent"

xattr -cr "$app"
codesign --force --timestamp --options runtime --entitlements "$ent" --sign "$dist_id" "$app"
codesign --verify --strict --verbose=2 "$app"

pkg="$out/$name.pkg"
productbuild --component "$app" /Applications --sign "$inst_id" "$pkg"
echo "built $pkg"

if [[ " $* " == *" --upload "* ]]; then
  : ${ASC_KEY_ID:?set ASC_KEY_ID} ${ASC_ISSUER_ID:?set ASC_ISSUER_ID}
  xcrun altool --validate-app -f "$pkg" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  xcrun altool --upload-app -f "$pkg" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "uploaded: the build shows in App Store Connect > TestFlight after processing"
fi
