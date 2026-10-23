#!/usr/bin/env bash
# Test helper for .github/workflows/ios-actions-test.yml; the action itself does not use it.
# Selects an installed Xcode whose version is neither $1 nor a $1.x patch, so that a following
# setup-ios step has to switch Xcode for its check to pass. The images default to the versions
# setup-ios is asked for, so without this a setup-ios that did nothing would still look fine.
# Prints the path of the Xcode it selected.
set -euo pipefail

target=${1:?usage: select-other-xcode.sh <xcode-version setup-ios will be asked for>}

for app in /Applications/Xcode*.app; do
  # setup-xcode skips symlinks too; the images alias every install several times.
  [ -L "$app" ] && continue
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/version.plist")
  case "$version" in
    "$target" | "$target".*) continue ;;
  esac
  sudo xcode-select -s "$app"
  echo "$app"
  exit 0
done

echo "No installed Xcode other than $target to switch away from." >&2
exit 1
