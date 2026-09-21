# Sample library, not shipped

Three short clips, a seeder that writes them into the real DB as speakers, topics,
albums, playlists and transcripts, and the provider that plays them back.

Not in any target: `project.yml` builds `Sources/` and `Resources/` only, so nothing
here reaches the app. Kept for manual testing of shelves, playback and transcripts
without connecting a bucket.

To use it, add this folder to the `EarToListen` target's sources in `project.yml`,
regenerate (`xcodegen`), and register the provider in `EarToListenApp.init`:

```swift
CloudProviderRegistry.shared.register(type: DemoProvider.providerType) { _ in DemoProvider() }
```

`DemoProvider.streamURL` resolves clips by bare name at the bundle root, so add
`DemoData/Audio` as a flattened group. Everything the seeder writes is tagged
`isDemo = true` (provider type `demo`), so `DemoDataSeeder.removeAll()` wipes it without
touching synced content. Migration `v27_drop_demo_library` deletes those rows on launch,
so seed after the migrator has run — which it has by the time anything calls the seeder.
