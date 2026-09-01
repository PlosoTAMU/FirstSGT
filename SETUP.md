# FirstSGT — Full Setup From Scratch

Reconstructed from source. Covers: new Google Cloud project + service account, new
spreadsheet, new Apple dev account, IPA build, SideStore install.

## What the app actually is

Single-target SwiftUI iOS app. No extensions, no entitlements, no third-party
packages, no CocoaPods/SPM dependencies. It talks directly to the Google Sheets
v4 REST API using a service account whose JSON key is bundled in the app. It
signs its own RS256 JWT via Security.framework (`GoogleAuthService.swift`), so
there is no Google SDK and no OAuth consent screen involved.

Hardcoded values you must change:

| Value | File | Line |
|---|---|---|
| Spreadsheet ID | `FirstSGT/SheetsService.swift` | 8 |
| Service-account JSON filename | `FirstSGT/GoogleAuthService.swift` | 25 |
| Bundle identifier `com.ploso.FirstSGT` | `FirstSGT.xcodeproj/project.pbxproj` | 272 |
| Development team `74JNGCVVMG` | `FirstSGT.xcodeproj/project.pbxproj` | 257 |

---

## Prerequisites

**Mac**
- macOS able to run Xcode 16.2 or newer (project `LastUpgradeCheck = 1620`, `SWIFT_VERSION = 6.0`)
- Xcode 16.2+ with command line tools
- Homebrew
- `ldid` — `brew install ldid`
- The FirstSGT source (this repo)

**Accounts**
- A Google account (free) — for Cloud Console + Sheets
- An Apple ID — free tier is fine, see caveats below
- SideStore requires a one-time USB connection to a computer to generate a pairing file

**Phone**
- iPhone on **iOS 16.4 or newer**
- Lightning/USB-C cable for the pairing step
- Fewer than 10 apps already sideloaded under the same free Apple ID

**Free Apple ID caveats**
- Apps expire after **7 days** and must be refreshed through SideStore
- Max **10 App IDs per 7 days**, max 3 apps installed at once on some accounts
- Bundle IDs are namespaced per team, but pick your own (`com.yourname.FirstSGT`)
  rather than reusing `com.ploso.FirstSGT` to avoid collisions
- A paid account ($99/yr) raises expiry to 1 year and removes the App ID churn

---

## Part 1 — Google Cloud: project, API, service account

1. Go to https://console.cloud.google.com and sign in.
2. Create a new project (top bar project picker → New Project). Name it whatever;
   the project ID does not need to be `firstsgt`.
3. Enable the Sheets API: **APIs & Services → Library** → search "Google Sheets API"
   → **Enable**. This is the only API needed. Do **not** enable Drive API; the app
   never touches it.
4. Create the service account: **APIs & Services → Credentials → Create Credentials
   → Service account**.
   - Name: anything (e.g. `firstsgt`)
   - Skip the optional "grant this service account access to project" and
     "grant users access" steps — no IAM roles are needed. Sheets access comes
     from sharing the spreadsheet, not from IAM.
5. Create the key: click the new service account → **Keys → Add Key → Create new
   key → JSON → Create**. A file downloads, named something like
   `myproject-a1b2c3d4e5f6.json`.
6. Open the JSON and copy the `client_email` value
   (`something@yourproject.iam.gserviceaccount.com`). You need it in Part 2.

> No OAuth consent screen, no OAuth client ID, no API key. The app authenticates
> purely as the service account.

---

## Part 2 — The spreadsheet

### 2a. Create and share it

1. Create a new Google Sheet.
2. **Share** → paste the service account's `client_email` → role **Editor** →
   uncheck "Notify people" → Send. Without Editor the app can read but every
   write (marking attendance, duplicating the weekly tab) fails.
3. Grab the spreadsheet ID from the URL:
   `https://docs.google.com/spreadsheets/d/`**`THIS_PART`**`/edit`

### 2b. Required tab structure

The app is rigid about layout. Every data tab must look like this:

```
      A              B         C          D          E        ...
1                  Monday                Tuesday                 <- day names, sparse
2                  AM PT     PM Formation  AM PT    ...          <- slot names
3   Smith, John     P         E (sick)    TBD
4   Doe, Jane       UA        P           P
...  (cadets through row 100 max)
30  Present         12        14          11
31  Total Outfit    45                                           <- reads col B from here down
32  Percentage      82%
```

Rules enforced by the code:

- **Row 1** = day names, **row 2** = slot names. A day name applies to every
  column to its right until the next non-empty day cell, so merged-looking day
  headers work — put the day once above its first slot.
- A column only becomes selectable if **both** its row-2 slot name and the
  carried-forward row-1 day are non-empty.
- Row 1 day names are matched with `contains`, case-insensitive, against
  `Monday`…`Sunday`. `Monday 4/13` works fine.
- **Cadets start at row 3** and are read through row 100. Column A is the name.
  Anything past row 100 is never read.
- **The stats section begins at the first row whose column A equals `Present`**
  (case-insensitive, exact match). Everything from there down is treated as a
  stat, not a cadet.
- Within stats, values are read from the currently selected slot column — until a
  row whose label contains `Total Outfit`, after which every remaining stat reads
  from **column B** instead.

### 2c. Group colors (column A background)

The app sorts cadets into groups by the **background color of their name cell**.
Set these exactly; unrecognized colors silently fall back to "white".

| Group | Approx RGB | Matching rule |
|---|---|---|
| Hidden (skipped entirely) | any dark gray | all channels < 0.5 |
| White / ungrouped | white | all channels > 0.95 |
| Yellow group | (1.00, 0.90, 0.60) | R>.90, .80<G<.95, .50<B<.75 |
| Blue group | (0.64, 0.76, 0.96) | .55<R<.75, .70<G<.85, B>.90 |
| Red group | (0.96, 0.80, 0.80) | R>.90, .70<G<.90, .70<B<.90, \|G−B\|<0.1 |
| Light blue group | (0.85, 0.92, 0.95) | .75<R<.92, G>.85, B>.90 |

Dark gray is the mechanism for hiding people (graduated, transferred) without
deleting the row.

### 2d. Status values

What you type into a cell drives the color in the app:

- `P` — present. Cadet is **filtered out of the list** (they're done).
- `UA` — unexcused absence → red
- `ROTC` → purple
- `E (reason)` → yellow if the reason contains `t-other`, `event`, `bag`,
  `refocus`, `sick`, or `out of town`; otherwise blue
- `TBD` or anything else → gray

A **cell note** (right-click → Insert note, not a comment) is fetched and shown
as detail in the app.

### 2e. The template tab

Weekly tabs are named `M/d-M/d` — Sunday through Friday, e.g. `4/12-4/17`. No
leading zeros, current year assumed.

You also need **template tabs** whose names contain both `TEMPLATE` and
`BASELINE` (case-insensitive). When the app opens and no tab matches the current
week, it duplicates the appropriate template into a new correctly named tab.

The app picks the template by semester, so keep one per semester and put the
season in the name:

| Date range | Template chosen |
|---|---|
| Aug 1 – Dec 9 | tab whose name also contains `FALL` |
| Dec 10 – Jul 31 | tab whose name also contains `SPRING` |

e.g. `FALL '26 - BASELINE TEMPLATE DO NOT CHANGE` and
`SPRING '27 - BASELINE TEMPLATE DO NOT CHANGE`.

Fallbacks, in order: any `TEMPLATE` + `BASELINE` tab regardless of season (logged
with a ⚠️), then the first tab whose name contains neither `-` nor `/`.

Set each template up with rows 1–2 filled in, cadet names and their group colors
in A3 down, and the stats block — but attendance columns blank.

---

## Part 3 — Point the app at your new Google setup

1. Drop the downloaded service-account JSON into `FirstSGT/` next to the Swift files.
2. Delete the old `FirstSGT/firstsgt-27133013414e.json`.
3. In Xcode, drag the new JSON into the project navigator. **Check "Copy items if
   needed"** and make sure the **FirstSGT target checkbox is ticked** — verify
   afterward under target → Build Phases → Copy Bundle Resources. If it isn't
   there, `loadCredentials()` throws `missingCredentials` and nothing works.
4. Edit `FirstSGT/GoogleAuthService.swift` line 25 — change the resource name to
   your filename **without the `.json` extension**:
   ```swift
   guard let url = Bundle.main.url(forResource: "myproject-a1b2c3d4e5f6", withExtension: "json"),
   ```
5. Edit `FirstSGT/SheetsService.swift` line 8 — paste your spreadsheet ID:
   ```swift
   static let spreadsheetId = "YOUR_SPREADSHEET_ID"
   ```
6. Build to the simulator (⌘R) to confirm it loads tabs and cadets before you
   bother with signing. Console logs `📖 [read] GET …` on success and
   `❌ [read] HTTP 403` if the sheet isn't shared with the service account.

---

## Part 4 — Apple developer account and signing

1. Create/sign in to an Apple ID at https://appleid.apple.com. Free is fine.
2. Xcode → **Settings → Accounts → +** → Apple ID → sign in.
3. Open `FirstSGT.xcodeproj`, select the **FirstSGT** target → **Signing &
   Capabilities**:
   - **Automatically manage signing**: on
   - **Team**: your new personal team (this replaces `74JNGCVVMG`)
   - **Bundle Identifier**: change to something unique, e.g.
     `com.yourname.FirstSGT`
4. Confirm the provisioning profile resolves with no red errors. If you see
   "Failed to register bundle identifier," change the bundle ID again — that one
   is taken.

---

## Part 5 — Build the IPA

Adapted from the Pulsor process, simplified: FirstSGT has **no app extension**,
so there is no `.appex` to sign and SideStore will not prompt about extensions.

1. In Xcode set the run destination to **Any iOS Device (arm64)**, then
   **Product → Archive**.
2. In Terminal:

```bash
cd ~/Library/Developer/Xcode/Archives/YYYY-MM-DD
cd *.xcarchive/Products/Applications/

cp -r FirstSGT.app ~/Desktop/FirstSGT.app
cd ~/Desktop

# strip existing signatures
find FirstSGT.app -name "_CodeSignature" -exec rm -rf {} \; 2>/dev/null
find FirstSGT.app -name "embedded.mobileprovision" -delete
codesign --remove-signature FirstSGT.app

# pre-sign with ldid — required, SideStore's bundled ldid chokes on fully
# unsigned binaries
ldid -S FirstSGT.app/FirstSGT

# package
mkdir Payload
cp -r FirstSGT.app Payload/
zip -ry FirstSGT.ipa Payload
rm -rf Payload
```

3. **If `ldid -S` prints any error, stop.** Do not package a bad binary; it will
   install and then crash on launch.

---

## Part 6 — SideStore on a fresh phone

SideStore's install flow changes between releases — check
https://sidestore.io/docs against these steps before starting.

1. **Pairing file.** Connect the iPhone to the Mac by cable, trust the computer,
   then generate a pairing file (SideStore's Jitterbug-style pairing tool, or
   `brew install libimobiledevice` then `idevicepair pair`). Save the `.mobiledevicepair` /
   `.plist` somewhere you can reach from the phone.
2. **Install SideStore itself.** Download `SideStore.ipa` from the official site
   and sideload it once using AltServer or `ideviceinstaller`, signing with the
   same Apple ID from Part 4. This is the one step that genuinely needs the
   computer.
3. **Trust the certificate** on the phone: Settings → General → VPN & Device
   Management → your Apple ID → Trust.
4. **Networking.** Modern SideStore refreshes over a local VPN (StosVPN) rather
   than needing AltServer running. Install and enable it, and allow the VPN
   profile when iOS asks.
5. **Open SideStore**, import the pairing file when prompted, and sign in with
   the same Apple ID.
6. **Install FirstSGT.** AirDrop `FirstSGT.ipa` to the phone, save to Files, then
   in SideStore use **+ → My Apps → select the IPA**. No extension prompt will
   appear (unlike Pulsor).
7. **Launch it.** First run hits the Sheets API immediately — if the list is
   empty, the sheet share in Part 2a is the usual culprit.

### Keeping it alive on a free account

- Refresh in SideStore **every 7 days** or the app stops launching.
- Refreshing requires the VPN active; SideStore can auto-refresh in the
  background if you leave it enabled.
- Re-signing does not touch app data.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Immediate crash / `missingCredentials` | JSON not in Copy Bundle Resources, or filename in `GoogleAuthService.swift:25` doesn't match |
| `❌ [read] HTTP 403` | Spreadsheet not shared with the service-account `client_email`, or Sheets API not enabled |
| `❌ [read] HTTP 404` | Wrong spreadsheet ID in `SheetsService.swift:8` |
| Tab list loads but no cadets | Names not starting at row 3, or column A cells are dark gray (treated as hidden) |
| No slots to pick | Row 2 slot names empty. Row 1 day names are optional — tabs without them (Football, Tasks) list the row 2 name alone |
| Everyone shows gray | Status strings don't match `P`/`UA`/`ROTC`/`E (...)` |
| Stats all zero | No row in column A exactly equal to `Present` |
| App creates a new tab every day | Existing tab name isn't `M/d-M/d` format |
| Stale tab list | Sheet names are cached 5 minutes (`SheetsService.swift:15`) |
| App won't launch after a week | Free-account 7-day expiry; refresh in SideStore |

## Security

The service-account private key is inside the app bundle. `unzip` the IPA and
it's readable in plain text, granting full Editor access to the spreadsheet. Use
a dedicated service account and a dedicated spreadsheet, don't distribute the
IPA beyond people you'd give sheet access to, and rotate the key in Cloud Console
(Keys → delete + create new) if it ever leaks.
