# Working in this repo

## Running the app

**Install on the physical iPhone, never a simulator** — unless explicitly told
otherwise. If no device is connected or the install fails, stop and say so;
don't fall back to a simulator.

```sh
xcodegen generate   # after adding/removing any file under Sources/ or Tests/
xcodebuild -project EarToListen.xcodeproj -scheme EarToListen \
  -destination 'id=<device-udid>' -skipPackagePluginValidation \
  -skipMacroValidation -allowProvisioningUpdates -derivedDataPath build/dd-install build
xcrun devicectl device install app --device <device-udid> \
  build/dd-install/Build/Products/Debug-iphoneos/EarToListen.app
```

`xcrun devicectl list devices` finds the UDID. `make ios` does all of the above, picking
the paired device and reading `DEVELOPMENT_TEAM` from `.env.local`. Shipping a build:
`make release`; `make help` for the rest, and `docs/release/` for the store listing.

Simulator builds are fine for *compiling and running tests* — just don't install
or launch there to demo a change.

## Build notes

- Adding a file means re-running `xcodegen generate` — the project is generated
  from `project.yml` and isn't in git.
- Regenerating invalidates the build graph; if a build fails with
  "failed to find blueprint corresponding to PIF GUID", wipe `build/` and retry.

## Lightweight and fast, as a requirement

This app must stay small and feel instant. It is a podcast player for someone's
own files — it earns nothing by being big.

**Budgets.** Release `.app` under 35 MB and falling, not rising. Measure with a
Release build, never Debug (Debug carries a ~50 MB `.debug.dylib` and means
nothing):

```sh
xcodebuild -project EarToListen.xcodeproj -scheme EarToListen \
  -configuration Release -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation -derivedDataPath build/dd-release build
du -sh build/dd-release/Build/Products/Release-iphoneos/EarToListen.app
```

**Dependencies are the size.** Almost the entire binary is third-party. Before
adding one, check what the app actually needs from it — `OpenAIChatClient` is
the precedent: *"one endpoint isn't worth a dependency."* A package that's
linked but unreferenced still costs; grep `Sources/` before assuming something
is used.

**Never do per-item I/O in a loop.** The two worst bugs this app has had were
both this shape: a per-track `cachedURL` that cost four filesystem calls each,
and a per-episode sidecar probe that cost five requests. One directory listing,
one bucket listing, then match in memory.

**Nothing heavy on the main actor, nothing eager in a long list.** Search folds
its haystacks once and scans off-main; every long list is `LazyVStack` or
`List`. A view body runs on every keystroke — it may not scan a library.

**Coalesce bursts.** `libraryDidChange` fires per imported file; anything
listening to it debounces (`refreshSoon`) rather than doing the work N times.
