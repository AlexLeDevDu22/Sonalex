#!/bin/sh
# After each Mac (Catalyst) build: install the app in /Applications and make it *the* app that
# opens sonalex:// links. Without this, every rebuild leaves a new copy in DerivedData and macOS
# ends up with no (or a stale) handler: "There is no application set to open the URL sonalex://…".
# Called by the scheme's build post-action (see project.yml); harmless for iPhone builds.
set -e
[ "${EFFECTIVE_PLATFORM_NAME}" = "-maccatalyst" ] || exit 0

APP="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"
DEST="/Applications/${FULL_PRODUCT_NAME}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$APP" ] || exit 0
rm -rf "$DEST"
ditto "$APP" "$DEST"
# Forget the build-folder copy, register the installed one.
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f -R "$DEST"
if /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "$DEST/Contents/Info.plist" | grep -q sonalex; then
  echo "Sonalex installée dans $DEST et déclarée pour sonalex://"
else
  echo "warning: $DEST/Contents/Info.plist ne déclare pas sonalex:// — relance xcodegen puis rebuild."
fi
