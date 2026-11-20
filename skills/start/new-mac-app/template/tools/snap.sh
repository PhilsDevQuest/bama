#!/bin/zsh
# Snapshots of every page in light and dark, with seed data, on a fresh test store.
# Usage: tools/snap.sh            all pages
#        APP_SNAPSHOT_PAGES=all,settings tools/snap.sh
#        APP_ACCENT=<id> tools/snap.sh                 another accent
#        tools/snap.sh -AppleShowScrollBars Always     see the scroll bars as people with a mouse see them
#
# The app is started with `open`, not as a child of this shell. Screen Recording
# permission belongs to the app that started the process: started from a shell
# it would be the terminal's or Claude's, started with `open` it is the
# permission of __APP_NAME__ itself (System Settings > Privacy & Security >
# Screen & System Audio Recording). Without it the captures fall back to a
# drawing that leaves sidebars and glass blank.
set -u
bundle=~/Applications/__APP_NAME__.app
store=/tmp/__APP_NAME__-test.store
shots=/tmp/__APP_NAME__-shots
log=/tmp/__APP_NAME__-snap.log
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/__BUNDLE_ID__.savedState
# Seed data only fills an empty store, so start from nothing.
rm -f $store $store-shm $store-wal $log
rm -rf $shots
env_args=(--env APP_STORE=$store --env APP_SEED=1 --env APP_SNAPSHOT=$shots)
# Options from the caller's environment reach the app too.
for name in APP_SNAPSHOT_PAGES APP_ACCENT APP_GRID; do
  [[ -n "${(P)name:-}" ]] && env_args+=(--env "$name=${(P)name}")
done
# -W waits until the app quits, -n starts a fresh copy even if one is open.
open -W -n "$bundle" "${env_args[@]}" --stdout $log --stderr $log --args "$@"
cat $log
if grep -q "fallback" $log; then
  echo "FAIL snapshots fell back: allow Screen Recording for __APP_NAME__"; exit 1
fi
if grep -q "SNAPSHOT inactive" $log; then
  echo "FAIL some windows were not active while captured: leave the Mac alone and run again"; exit 1
fi
