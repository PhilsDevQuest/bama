# App Store apps

Read this when `docs/BRIEF.md` says **Distribution: Mac App Store**. A
personal app skips it. An App Store app runs in the App Sandbox, and every
part of the template still works, with the rules below.

## Contents

- Two builds
- Where data lives
- Files and folders the user picks
- Network, sockets, other programs
- Entitlements
- Privacy manifest
- Agent CLI and MCP in the sandbox
- In-app purchases
- Release
- When to switch to an Xcode project
- App Review gotchas

## Two builds

| Build | Command | Use for |
| --- | --- | --- |
| Normal | `./build.sh` | Every story: snapshots, self-test, test stores in `/tmp` |
| Sandboxed | `./build.sh --sandbox` | What App Store users run |
| Check | `tools/sandbox-check.sh` | End of every milestone, and after any story that touches files, network, or other programs |

Snapshot mode and the test stores write to `/tmp` and run
`screencapture`. The sandbox blocks both, so stories are built and checked
in the normal build. `sandbox-check.sh` builds the sandboxed app, runs the
self-test inside the container, checks the agent CLI, and installs the
normal build again.

Check: `tools/sandbox-check.sh` prints `PASS sandbox check`.

## Where data lives

`URL.applicationSupportDirectory` points into the container in the
sandboxed build: `~/Library/Containers/<bundle-id>/Data/Library/Application Support/`.
The template's code needs no change. The two builds keep separate data on
the developer's Mac. That is expected: real data lives in the sandboxed
build, sample data in the normal one.

Never build a path from `NSHomeDirectory()` plus a folder name, or from
`~`. In the sandbox `~` is the container. Ask the system for the directory
(`URL.applicationSupportDirectory`, `URL.cachesDirectory`,
`URL.temporaryDirectory`).

## Files and folders the user picks

The app can open only what the user picks in an open panel or drops on the
window. To keep that access after a restart, save a security-scoped
bookmark. One type owns this, used for every folder the app remembers:

```swift
struct FolderAccess {
    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope,
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a saved bookmark and runs `work` with access. Returns a fresh
    /// bookmark when the old one went stale; save it.
    static func withAccess<T>(_ data: Data, _ work: (URL) throws -> T) throws -> (T, Data?) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        let started = url.startAccessingSecurityScopedResource()
        if !started && isSandboxed { throw CocoaError(.fileReadNoPermission) }
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return (try work(url), stale ? try bookmark(for: url) : nil)
    }

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }
}
```

- Store the bookmark `Data` in the model next to a display path. The path
  is for people, the bookmark is for access.
- A folder on a NAS or an external drive can be offline. Show it as
  offline with a "Locate" button, never as an error dialog at launch.
- iCloud Drive, Google Drive for desktop, Dropbox, and mounted SMB shares
  are ordinary folders here. Files in iCloud can be "not downloaded":
  check `URLResourceValues.ubiquitousItemDownloadingStatus` before reading.
- A self-test that needs a folder creates it in the container
  (`URL.temporaryDirectory`), so it runs without a panel.

Check: a story that remembers a folder passes `sandbox-check.sh` and
still reads the folder after the app restarts.

## Network, sockets, other programs

- Outgoing requests (APIs, uploads, `http://localhost:<port>`) need
  `com.apple.security.network.client`.
- Listening on a TCP port needs `com.apple.security.network.server`.
  A Unix socket inside the container needs nothing.
- The sandboxed app can run only programs inside its own bundle, signed
  with `com.apple.security.app-sandbox` and `com.apple.security.inherit`.
  It cannot run `node`, `python`, `ffmpeg`, `git`, or `claude` from the
  user's Mac. Design such work the other way round: the outside tool calls
  the app through its agent CLI or MCP server.
- To open another app or a URL, use `NSWorkspace.shared.open(_:)` or
  `openApplication(at:configuration:)`, never `Process` with `/usr/bin/open`.
- Keychain items (`SecItemAdd`) work without an entitlement. API keys and
  tokens go there, never into the database or `UserDefaults`.

## Entitlements

`AppStore/App.entitlements` starts with the sandbox, user-picked files,
and bookmarks. Add a line only when a story needs it, and write the reason
in the story. App Review asks.

| Need | Entitlement |
| --- | --- |
| Internet, APIs, local web servers | `com.apple.security.network.client` |
| Accept connections | `com.apple.security.network.server` |
| Read the Movies, Music, or Pictures folder without a panel | `com.apple.security.assets.movies.read-write` (and `.music`, `.pictures`) |
| Camera, microphone | `com.apple.security.device.camera`, `.audio-input`, plus the usage text in Info.plist |
| Calendars, contacts | `com.apple.security.personal-information.calendars`, `.addressbook` |
| Share data with an extension or a second app | `com.apple.security.application-groups`, needs the provisioning profile |

## Privacy manifest

`AppStore/PrivacyInfo.xcprivacy` declares `UserDefaults` (reason
`CA92.1`). Add a reason for each other "required reason" API the app uses:

| API | Reason |
| --- | --- |
| File dates (`creationDate`, `contentModificationDate`) of files the user picked | `3B52.1` |
| File dates inside the container | `C617.1` |
| Free disk space, shown to the user | `85F4.1` |
| Free disk space, checked before writing | `E174.1` |
| System boot time (`systemUptime`) for elapsed time | `35F9.1` |

Check: every API from the table that the code calls has its reason in the
manifest (`grep -rn contentModificationDate Sources` and so on).

## Agent CLI and MCP in the sandbox

The CLI and the MCP server are the app binary. Started from Terminal or by
Claude, the sandboxed binary gets the same container as the app, so the
socket in Application Support works in both builds. `sandbox-check.sh`
proves it with `status --json`.

- `build.sh` links `~/.local/bin/<cli>` on the developer's Mac. An App
  Store install cannot write there. Add a Settings page "Claude and agents"
  that shows the full path
  (`/Applications/<App>.app/Contents/MacOS/<App>`), the `claude mcp add`
  line, and the Claude Desktop JSON, each with a Copy button.
- A switch per area of the app sets what agents may do: off, read, draft,
  write. The command router checks it before `run`, so the CLI, the MCP
  server, and an in-app chat all follow the same rules.
- If the CLI cannot open the app in the sandbox, switch the launch in
  `AgentSocket.swift` from `/usr/bin/open -g` to `NSWorkspace.shared.openApplication`
  with `configuration.activates = false`.

## In-app purchases

StoreKit 2: `Product.products(for:)`, `product.purchase()`, and
`Transaction.currentEntitlements` at launch and in `Transaction.updates`.

- Put product ids in one enum. Unlock features from one `Entitlements`
  type the views read, never from scattered checks.
- Local purchase tests need a `.storekit` file and an Xcode scheme. Until
  the project moves to Xcode, test with a Sandbox Apple Account on a
  TestFlight build.
- Show "Restore purchases" in Settings, and the terms and privacy links on
  the paywall.

## Release

1. Join the Apple Developer Program. Create the App ID (the bundle id),
   the app record in App Store Connect, a "Mac App Store" provisioning
   profile, and the certificates "Apple Distribution" and the installer
   certificate.
2. Save the profile as `AppStore/embedded.provisionprofile` (git ignores it).
3. Raise `CFBundleShortVersionString` in `Info.plist.in` for each release.
4. Run `TEAM_ID=<team> tools/appstore.sh`. It builds a universal binary,
   embeds the profile, signs with the hardened runtime, and writes a
   signed `.pkg`.
5. Upload with `--upload` and an App Store Connect API key, or drag the
   `.pkg` into Apple's Transporter app. Test it in TestFlight first.

Check: the build shows in App Store Connect under TestFlight.

## When to switch to an Xcode project

Move to XcodeGen (`project.yml`, see SKILL.md) when the app needs a Share
extension, widgets, App Intents, a `.storekit` test file, or when
`appstore.sh` fails on signing details Xcode would handle. Keep the
targets, the entitlements file, and the privacy manifest. Point
`tools/snap.sh`, `selftest.sh`, and `sandbox-check.sh` at the app that
`xcodebuild` builds. Do it in one story with no feature changes.

## App Review gotchas

- Core features work offline, without an account, and without other
  software installed. Integrations (Claude, cloud services, social
  accounts) are optional and say so.
- The app never downloads and runs code.
- Every entitlement and every permission prompt has a visible reason in
  the app.
- An app that signs in to other services needs a test account or a demo
  mode for the reviewer. Write it in the review notes.
- Subscriptions show price, period, and what unlocks, before the purchase.

Done when `tools/sandbox-check.sh` prints `PASS sandbox check`, the
privacy manifest lists every required reason API, and `tools/appstore.sh`
builds a signed `.pkg`.
