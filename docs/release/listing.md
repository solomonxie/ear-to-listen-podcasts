# Publishing Ear to Listen — step by step

Every field below is ready to paste. `TODO` = only you can supply it.
App Store Connect paths start at **Apps → Ear to Listen →**.

| | |
|---|---|
| Bundle ID | `com.example.eartolisten` |
| iCloud container | `iCloud.com.example.eartolisten` |
| SKU | `eartolisten-ios` |
| Version | `1.0` (`MARKETING_VERSION` in `project.yml`) |
| Build | timestamp, set by `scripts/release-ios.sh` |
| Devices | iPhone only, portrait (`TARGETED_DEVICE_FAMILY = 1`) — no iPad screenshots needed |
| Min iOS | 17.0 |
| Privacy Policy URL | `https://github.com/solomonxie/ear-to-listen-podcasts/blob/master/docs/release/privacy-policy.md` |
| Support URL | `https://github.com/solomonxie/ear-to-listen-podcasts/issues` |

**Before anything else:** those two URLs must resolve for Apple. Either make the GitHub
repo public, or host the policy somewhere else and change the URL in both places below.
A 404 on the privacy policy is an automatic rejection.

---

## 0. The two real review risks — read this first

**2.1, empty app.** A fresh install is empty on purpose. The first screen offers "Try the
sample library" (Demo mode, ships in Release), so the reviewer needs no bucket. The
[App Review Notes](#app-review-notes) point there first.

<a id="43-spam"></a>**4.3 Spam, "saturated category".** 1.0 was rejected under 4.3 once:
read as one more podcast player. Everything the reviewer sees must lead with what no
podcast player does — search inside what was said, correctable transcripts, the
listener's own storage, no catalogue:

- Subtitle, promo text, first paragraph of the description, keywords: transcript/search first.
- Primary category Productivity, not Entertainment.
- Screenshots in the order under [Screenshots](#screenshots), captioned.
- Review Notes give a 60-second path through those features.
- Reply in Resolution Center with the text below, plus a screen recording of that path.

Resolution Center reply:

```
Thank you for the review. We'd like to clarify how Ear to Listen differs from podcast players on the App Store.

It has no catalogue, no RSS/feed directory and no recommendations — it cannot find or subscribe to any show. It is a tool for searching spoken audio the user already owns:

1. Full-text search of what was said. Recordings are transcribed on the device (Apple Speech); search returns the matching line with its context and starts playback at that second.
2. Correctable transcripts. Lines are edited in place against their neighbours, and corrections are fed back as vocabulary hints for the rest of the recording.
3. The user's own storage as the only source: Amazon S3, Tencent COS, Alibaba OSS, Azure Blob, Google Cloud Storage, or a folder in Files — no server of ours in between.
4. Library cleanup for files with poor tags: titles, speakers and artwork proposed from the transcript, every change reviewed before it is applied.
5. Backups as a plain .zip in the user's own iCloud Drive or bucket.

The new build opens to "Try the sample library", which loads transcribed sample recordings with no credentials. The attached recording shows the path described in the Review Notes: search for a spoken phrase, play from the hit, correct a transcript line.

We've also updated the subtitle, description, category and screenshots so they reflect this.
```

- [ ] Replace the stale demo-bucket TODOs below, or delete them — demo mode covers review.

## 1. Apple Developer account

- [ ] developer.apple.com → Account → membership **active** (paid; Individual is fine).
- [ ] App Store Connect → **Business** (Agreements, Tax, and Banking) → no pending
      agreement banner. Free app: no Paid Apps agreement and no banking needed.
- [ ] Note your **Team ID** (developer.apple.com → Membership details). Everything below
      reads it from the environment, never from git.

```sh
echo 'DEVELOPMENT_TEAM=YOURTEAMID' > .env.local   # gitignored
```

## 2. Xcode

- [ ] Xcode → Settings → **Accounts** → signed in with the developer Apple ID; the team
      shows under it.
- [ ] `xcodegen generate` succeeds (`brew install xcodegen` if missing).

## 3. Bundle ID and iCloud container

Automatic signing creates the bundle ID the first time you build to a device. Verify at
developer.apple.com → Certificates, Identifiers & Profiles:

- [ ] Identifiers → `com.example.eartolisten` exists.
- [ ] **iCloud** capability checked, with container `iCloud.com.example.eartolisten`
      assigned (create it there if automatic signing didn't).
- [ ] `ExportOptions.plist` sets `iCloudContainerEnvironment = Production`, so the shipped
      build writes to the container TestFlight and the store can see — already done.

## 4. Run on the iPhone

```sh
make ios                                 # Debug, onto the paired phone
CONFIG=Release scripts/install-ios-device.sh
```

Smoke-test: connect a bucket, sync, play an episode, download one, transcribe a stretch,
correct a line, save a moment, search for something said, turn on iCloud backup.

## 5. Create the app in App Store Connect

**Apps → + → New App**

| Field | Value |
|---|---|
| Platforms | iOS |
| Name | `Ear to Listen` |
| Primary Language | English (U.S.) |
| Bundle ID | `com.example.eartolisten` (dropdown) |
| SKU | `eartolisten-ios` |
| User Access | Full Access |

If `Ear to Listen` is taken, the fallbacks in order: `Ear to Listen: Podcasts`,
`Ear to Listen Player`, `Ear to Listen — Your Podcasts`. The **Name** is the only field
that has to be unique; the [subtitle](#general--app-information) and everything else stay
as written.

## 6. Listing content

Fill the pages in [App Store Connect pages](#app-store-connect-pages). Screenshots: see
[Screenshots](#screenshots).

## 7. Archive and upload

```sh
make release
```

Runs the tests, then archives Release, signs for App Store, exports the `.ipa`, and uploads
it if upload credentials are set (`make help`, or the header of `scripts/release-ios.sh` —
App Store Connect API key, or Apple ID plus app-specific password). With neither, it stops
at the `.ipa` and prints the path: drag that into **Transporter.app** and hit Deliver.
`make archive` stops there deliberately, credentials or not.

This replaces Product → Archive → Distribute App entirely; the GUI route below is only a
fallback.

Build number is a timestamp, so re-running always produces a higher build than the last.
Processing in App Store Connect takes 15–60 min, then an email: "build has completed
processing".

Fallback, Xcode GUI: `open EarToListen.xcodeproj` → destination **Any iOS Device (arm64)**
→ Product → **Archive** → Organizer → **Distribute App** → App Store Connect → Upload.

## 8. TestFlight

- [ ] App Store Connect → **TestFlight** → the build shows no "Missing Compliance" (see
      [Export compliance](#export-compliance)).
- [ ] Internal Testing → **+** group `Me` → add your Apple ID → install via the TestFlight
      app on the iPhone.
- [ ] Same smoke test as step 4, on the TestFlight build — this is the exact binary Apple
      reviews. Check iCloud backup specifically: it's the Production container now, not
      the Development one your device builds used.

## 9. Submit

- [ ] `iOS App → 1.0 Prepare for Submission` → **Build** → **+** → pick the build.
- [ ] Every page in [App Store Connect pages](#app-store-connect-pages) filled; App
      Privacy published.
- [ ] Review Notes lead with "Try the sample library" and the 60-second path (step 0).
- [ ] **Add for Review** → **Submit for Review**.

## 10. App Review

- Typical: 24–48 h. Status: Waiting for Review → In Review → Pending Developer Release.
- Rejection → **Resolution Center**: reply there, or fix and re-run
  `make release` (new build number is automatic), attach the new build,
  resubmit. No version bump needed for a rejected build.
- Likely questions, and the answers: [App Review Notes](#app-review-notes).

## 11. Release

- [ ] Status **Pending Developer Release** → `1.0` page → **Release This Version**. Live
      within ~24 h.
- [ ] `git tag v1.0 && git push --tags`.

---

## Screenshots

App Store Connect's **iPhone 6.9" Display** slot is the only required one for an
iPhone-only app: exactly `1320 × 2868` (or `1290 × 2796`). Everything smaller is scaled
from it automatically.

Captured 2026-10-08 (simulator, demo library), captioned, 6 shots in upload order — the
features no podcast player has come first ([4.3](#43-spam)):

1. search — a transcript hit · 2. transcript · 3. welcome (first run) · 4. album · 5. speaker · 6. home

- `docs/release/screenshots/` — English
- `docs/release/screenshots/zh-Hans/` — 简体中文, same order (`08-ai-keys.jpg` is the China-storefront review attachment, not a store shot)

Recapture: build with `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) SCREENSHOTS'`,
launch each shot with `-screen <name>` (`-query "local church"` / `福贵` for search,
`-track Melatonin` / `-track 活着` for the transcript; `welcome` needs a fresh install), save as
`<name>.png`, then `venv/bin/python scripts/store-captions.py <dir> <out> en|zh-Hans`.

App Preview video: skip for 1.0.

---

## App Store Connect pages

### `iOS App → 1.0 Prepare for Submission`

| Field | Value |
|---|---|
| Previews and Screenshots | [Screenshots](#screenshots) |
| Promotional Text | below |
| Description | below |
| Keywords | below |
| Support URL | `https://github.com/solomonxie/ear-to-listen-podcasts/issues` |
| Marketing URL | leave blank |
| Version | `1.0` |
| Copyright | `2026 solomonxie` |
| Routing App Coverage File | leave blank |
| Build | the uploaded build (step 9) |
| App Review → Sign-In Required | Off |
| App Review → Contact First / Last Name | TODO |
| App Review → Phone | TODO (with country code, e.g. `+1 …`) |
| App Review → Email | TODO |
| App Review → Notes | below |
| App Review → Attachment | none |
| Version Release | **Manually release this version** |

Promotional Text (140/170):

```
Find the moment something was said. Your own recordings, played from your own storage, transcribed on the phone and searchable line by line.
```

Description:

```
Search your audio for what was said. Ear to Listen transcribes the recordings you already own — talks, lectures, interviews, podcasts you've archived — and finds the line you remember, then plays from that exact second.

It has no catalogue and no feed directory: it doesn't find or subscribe to anything. Point it at your own storage — an Amazon S3, Tencent COS, Alibaba OSS, Azure Blob or Google Cloud Storage bucket, or a folder on this phone — and it turns the files there into a searchable library: transcripts you can correct, speakers, albums, topics, saved moments.

No account, no subscription, and no server of ours in between.

SEARCH WHAT WAS SAID
• One search covers titles, file paths, episode and collection notes, speaker bios, topics, playlists, and the notes typed onto saved moments
• Then the transcripts themselves — a hit shows the line with its neighbours and plays the episode from that second

TRANSCRIPTS YOU CAN FIX
• Transcribe on the device with Apple's speech recognition, or with a cloud service using your own key
• Lyric-style, following along as it plays; tap any line to play from it
• Correct a line in place, between the lines you're correcting it against
• Your corrections come back as hints, so the rest of the episode comes out better
• Saved as it goes, so a half-finished transcript is still worth having

YOUR FILES, YOUR LIBRARY
• Connect a bucket with your own keys, or a folder from Files
• Sync on a schedule you set per source, or on demand
• Tags are read once and then yours to correct — title, speaker, artwork, notes
• Every episode shows its file path as well as its title, because a whole folder of files routinely shares one title tag
• Albums, speakers, playlists, favourites and Listen Later; browse by year, topic or the words a show keeps coming back to

PLAYBACK
• Streams straight from your storage, keeping a copy for offline as you listen
• Downloads sit in the Files app, copyable off the phone like anything else
• Background audio and lock-screen controls
• Save a moment with a note from the player or the mini bar, and tap it later to hear it

BACKUP YOU CAN SEE
• Playlists, hand edits and their images, transcripts and corrections — a plain .zip, never your episode files
• Automatically to your own iCloud Drive, visible in Files under "Ear to Listen"
• And to your own bucket, if you want it beside the episodes
• Delete and reinstall the app and it puts itself back on first launch
• Export or import by hand at any time — you can walk away with your data

OPTIONAL AI, YOUR OWN KEY
Add a key from DeepSeek, Qwen, Kimi, GLM or Doubao — or point it at any compatible server — and it will draft better titles and show names during a sync, summarise an episode, or sort out a whole album in one pass — every suggestion shown to you before it lands. Keys live in the Keychain on this device, are never included in backups, and are never sent to us. Add more than one and they fall back to each other on a rate limit. Skip all of it and the app works the same.

Free. No ads, no analytics, no tracking, no in-app purchases.

English and 简体中文.
```

Keywords (97/100 — "listen" and "audio" are omitted, the name and subtitle already index
them; transcript/search first, generic player words last, see [4.3](#43-spam)):

```
transcript,transcribe,speech,search,podcast,lecture,s3,bucket,self-hosted,oss,cos,notes,audiobook
```

<a id="app-review-notes"></a>App Review Notes:

```
No account and no login. Fastest way to review: on the first screen tap "Try the sample library" (also Settings → Demo mode). It loads 12 short spoken episodes with transcripts — no credentials needed.

What sets the app apart from a podcast player — a 60-second path:
1. Type "local church" into the search bar. The last section, "In transcripts", shows the line where it was said; tap it and playback starts at that second.
2. In the player, open Transcript. Tap a line to jump to it; tap ✎ Edit to correct it in place. Corrections are fed back as vocabulary hints for the rest of the episode.
3. Open any album → ⋯ → "Analyze with AI…" proposes titles for the whole album from its transcripts; each change is reviewed before it lands (needs the reviewer's own AI key; optional).

The app has no catalogue, feed directory or recommendations. Its only sources are storage the user owns: an S3 / Tencent COS / Alibaba OSS / Azure Blob / Google Cloud Storage bucket, or a folder in Files (Settings → Sources).

Optional features a reviewer may want to skip:
- AI suggestions (Settings → AI Keys): requires the reviewer's own API key from a provider such as DeepSeek. Off by default; the rest of the app works without it.
- iCloud Drive backup (Settings → Sync & Backup): optional; the app is fully functional without it.

China mainland: the app reads the App Store storefront (StoreKit Storefront.current). On the China storefront it offers only AI providers licensed in mainland China (DeepSeek, Qwen, Kimi, GLM, Doubao) and a user-supplied custom server; ChatGPT/OpenAI and every other unlicensed provider, and cloud transcription through them, are not offered or shown, and no metadata in any localization refers to them. A screen recording of the China build's AI settings is attached.

All library data is stored in a local SQLite database on the device. We operate no server, have no accounts, and receive no user data. The only networking the app does is to the storage the user configures and, if enabled, to the AI provider the user supplies a key for.
```

What's New: not shown for a first version. From 1.1 on, write it here.

### `General → App Information`

| Field | Value |
|---|---|
| Name | `Ear to Listen` |
| Subtitle (27/30) | `Search what your audio said` |
| Category — Primary | Productivity |
| Category — Secondary | Entertainment |
| Content Rights | **No**, it does not contain, show, or access third-party content |
| Age Rating | **Edit** → answers below → result **4+** |
| License Agreement | Apple standard EULA (default) |
| Privacy Policy URL | `https://github.com/solomonxie/ear-to-listen-podcasts/blob/master/docs/release/privacy-policy.md` |

Age rating questionnaire — every answer:

| Section | Answer |
|---|---|
| Parental controls / age assurance | No |
| Unrestricted web access | **No** — the app has no browser; the artwork "Search" link hands a URL to the system default browser and leaves the app |
| User-generated content | **No** — the listener's own files, visible only to them, shared with nobody |
| Messaging and chat | No |
| Advertising | No |
| Violence, sexual content, profanity, horror, mature themes | None |
| Alcohol, tobacco, drugs | None |
| Medical or treatment information / health & wellness | None |
| Gambling, simulated gambling, contests, loot boxes | None / No |
| Made for Kids | No |

Regional (Korea, China Mainland, Vietnam) — leave unset.
**Digital Services Act** trader status: **Not a trader** (free, no monetisation). If App
Store Connect blocks EU availability without it, answer this under Business → Compliance.

### `App Store → Trust & Safety → App Privacy`

| Field | Value |
|---|---|
| Privacy Policy URL | same as above |
| Do you or your third-party partners collect data from this app? | **No, we do not collect data from this app** |

Then **Publish**. The label shows "Data Not Collected".

Why that's the honest answer: data leaves the device only to destinations the *user*
configures — their bucket, their iCloud, their AI provider under their own account. None
of those are our partners and none of it reaches us.

True only while there's no analytics or crash SDK. Re-check before every submission:

```sh
grep -rniE "analytics|firebase|sentry|amplitude|mixpanel|posthog|bugsnag" project.yml
```

### `App Store → Trust & Safety → App Accessibility`

Skip for 1.0 rather than over-claim.

### `App Store → Monetization → Pricing and Availability`

| Field | Value |
|---|---|
| Base Country or Region | United States (USD) |
| Price | **Free** ($0.00) |
| Availability | All countries or regions |
| Tax Category | App Store software (default) |
| iPhone and iPad Apps on Apple Silicon Macs | **Off** for 1.0 (iCloud Files paths and on-device speech untested on Mac) |
| Apple Vision Pro | Off |

### Not needed for 1.0

In-App Purchases, Subscriptions, In-App Events, Custom Product Pages, Product Page
Optimization, Promo Codes, Game Center, Featuring Nominations.

---

## Export compliance

No page for it in App Store Connect — nothing to fill in. `ITSAppUsesNonExemptEncryption
= false` is set in `project.yml` and answers it at upload. The app uses HTTPS/TLS, the
Keychain, and HMAC-SHA256 to sign storage requests (S3 SigV4, Azure Shared Key, Google
service-account JWT) — authentication only, all Apple-exempt.

Verify: TestFlight → the build is **not** marked "Missing Compliance". Only if it is:
**Manage** → **None of the algorithms mentioned above**.

---

## Optional: 简体中文 localization

The app ships `zh-Hans` (`Resources/Localizable.xcstrings`). App Store Connect → App
Information → language dropdown (top right) → **Add Chinese (Simplified)**, then switch to
it on the `1.0` page.

| Field | Value |
|---|---|
| Name | `Ear to Listen` |
| Subtitle (10/30) | `按说过的话搜你的音频` |
| Privacy Policy URL | same |
| Keywords (48/100) | `转写,文字稿,语音转文字,搜索,录音,讲座,播客,有声书,对象存储,私有云,COS,OSS,笔记` |
| Screenshots | upload `docs/release/screenshots/zh-Hans/*.jpg` |

Wording follows the app's own zh-Hans UI (`Resources/Localizable.xcstrings`): 播放列表 not 歌单,
主讲人 not 讲者, 文字记录 for transcript, 个人私有云端 for a bucket source. Keep them in step
if either changes.

Promotional Text (51/170):

```
记得说过哪句话，就能找到那一秒。你自己的录音，从你自己的存储播放，在手机上转成文字，一句一句都搜得到。
```

Description:

```
按“说过的话”搜你的音频。Ear to Listen 把你手上已有的录音——讲座、课程、访谈、存下来的播客——转成文字记录，记得哪句话，就能搜到那一句，并从那一秒开始播放。

它没有内容库，也没有节目目录：不推荐、不订阅、不分发任何内容。把它接到你自己的存储——腾讯云 COS、阿里云 OSS、Amazon S3、Azure Blob、Google Cloud Storage，或者手机上的一个文件夹——它就把里面的文件整理成一个能搜索的资料库：可以手改的文字记录、主讲人、专辑、标签、存下的时刻。

不用注册，没有订阅，你的音频也不会经过我们的服务器。

搜“说过的话”
• 一次搜索，标题、路径、单集和合集的备注、主讲人简介、标签、播放列表、你在时刻上记的笔记，全都在内
• 再往下搜到文字记录里：命中的那句连同前后几句一起显示，点一下就从那一秒开始放

文字记录，可以手改
• 本机语音识别转写，音频不出手机；也可以用自己的密钥接云端转写服务
• 像歌词一样跟着播放滚动，点哪一行就从哪一行放
• 原地修正一句，上下文就在旁边对照着
• 你改过的词会作为提示带进后面的转写，越改越准
• 边转边存，转了一半的稿子照样能用

文件是你的，资料库也是你的
• 用自己的密钥接入存储桶，或者直接从“文件”App 挑一个文件夹
• 每个来源各自设同步频率，想同步随时点一下
• 标签只读一遍，之后随你改：标题、主讲人、封面、备注
• 每一集都把文件路径和标题一起显示——一个文件夹几十个文件共用一个标题的事，太常见了
• 专辑、主讲人、播放列表、收藏、稍后收听；按年份、标签，或者按一档节目反复提到的词来翻

播放
• 直接从你的存储流式播放，边听边留一份离线副本
• 下载好的文件就在“文件”App 里，想拷到哪儿都行
• 后台播放、锁屏控制
• 听到哪儿想记一下，在播放页或底部迷你条上点一下存个时刻、写句备注，之后点开直接回到那里

备份看得见、拿得走
• 播放列表、手动编辑过的信息和图片、文字记录和修正——打成一个普通的 .zip，从不包含音频文件本身
• 自动备到你自己的 iCloud 云盘，“文件”App 里的“Ear to Listen”文件夹就能看见
• 也可以顺手备一份到你的存储桶，和音频放在一起
• 删了重装，第一次打开就自动恢复
• 随时手动导出、导入——数据想带走就带走

AI 是可选的，密钥用你自己的
填一个 DeepSeek、通义千问、Kimi、智谱 GLM 或豆包的密钥（任何兼容接口的自定义服务也行），同步的时候它就能帮你把标题和节目名拟得像样一点，给一集写个摘要，或者一口气把整张专辑理顺——每一条建议都先给你看，点了才生效。密钥存在本机钥匙串，不进备份，也永远不会发给我们。多填几个，哪个限流就自动换下一个。一个都不填，应用照样好用。

免费。没有广告，没有统计，没有追踪，没有内购。

支持简体中文和英文。
```
