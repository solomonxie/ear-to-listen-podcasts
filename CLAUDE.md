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

`xcrun devicectl list devices` finds the UDID.

Simulator builds are fine for *compiling and running tests* — just don't install
or launch there to demo a change.

## Build notes

- `-skipPackagePluginValidation` is required; this Xcode otherwise fails
  validating the AWS SDK's Smithy code-gen plugin.
- Adding a file means re-running `xcodegen generate` — the project is generated
  from `project.yml` and isn't in git.
- Regenerating invalidates the build graph; if a build fails with
  "failed to find blueprint corresponding to PIF GUID", wipe `build/` and retry.
