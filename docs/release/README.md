# App Store Release

Bundle ID `com.solomonxie.eartolisten` · iOS 17+ · iPhone only, portrait · Free.

- [`listing.md`](listing.md) — the step-by-step plan and every App Store Connect field,
  ready to paste
- [`privacy-policy.md`](privacy-policy.md) — the policy; its GitHub URL is the Privacy
  Policy URL in the listing
- `screenshots/6.9` (required slot), `screenshots/6.5` (legacy) — upload-ready, from
  `scripts/store-screenshots.sh`

```sh
echo 'DEVELOPMENT_TEAM=YOURTEAMID' > .env.local   # gitignored; never commit a team id
make release                                      # test → archive → .ipa → App Store Connect
```

`make archive` stops at the `.ipa` when the upload is going through Transporter by hand.
`make help` lists the rest, including the upload credentials.

Versioning: `MARKETING_VERSION` in `project.yml` is the user-visible version — bump it per
release. The build number is a timestamp the script sets, so it never needs editing.

Read [step 0 of `listing.md`](listing.md#0-the-one-real-review-risk--read-this-first)
before submitting: a fresh install is empty until a source is connected, so App Review
needs demo bucket credentials in the review notes.
