#!/bin/zsh
# Builds __APP_NAME__ with the App Sandbox, runs the self-test inside the sandbox,
# checks the agent CLI if the app has one, then installs the normal build again.
# Exit code 0 when everything passed. Run it at the end of every milestone.
# Usage: tools/sandbox-check.sh          check, then restore the normal build
#        tools/sandbox-check.sh --keep   leave the sandboxed build installed
set -u
here=${0:A:h:h}
app=~/Applications/__APP_NAME__.app
bin=$app/Contents/MacOS/__APP_NAME__
# The sandboxed app can only write inside its container. Its tmp folder exists
# once the app has started, so the test store goes there instead of /tmp.
container=$HOME/Library/Containers/__BUNDLE_ID__/Data
store=$container/tmp/sandbox-self.store
failed=0
restore() {
  if [[ " $* " == *" --keep "* ]]; then echo "sandboxed build stays installed"; return; fi
  "$here/build.sh" >/dev/null && echo "normal build installed again"
}

"$here/build.sh" --sandbox || { echo "FAIL sandbox build"; exit 1; }

if codesign -d --entitlements - "$app" 2>/dev/null | grep -q "com.apple.security.app-sandbox"; then
  echo "PASS signed with the App Sandbox"
else
  echo "FAIL the app is not signed with com.apple.security.app-sandbox"; failed=1
fi

rm -rf ~/Library/Saved\ Application\ State/__BUNDLE_ID__.savedState
rm -f $store $store-shm $store-wal
if APP_STORE=$store $bin --selftest; then
  echo "PASS self-test in the sandbox"
else
  echo "FAIL self-test in the sandbox. Look for file access outside the container,"
  echo "     a missing entitlement, or a Process call (bama new-mac-app skill, app-store.md)"
  failed=1
fi

# The agent CLI: the sandboxed CLI must reach the sandboxed app over its socket.
agent_dirs=("$here"/Sources/*/Agent(N))
if (( ${#agent_dirs} )); then
  if $bin status --json >/dev/null 2>&1; then
    echo "PASS agent CLI reaches the sandboxed app"
  else
    echo "FAIL agent CLI in the sandbox: run \`$bin status --json\` and read the error"; failed=1
  fi
  osascript -e 'quit app "__APP_NAME__"' 2>/dev/null || true
fi

restore "$@"
[[ $failed == 0 ]] && echo "PASS sandbox check" || { echo "FAIL sandbox check"; exit 1; }
