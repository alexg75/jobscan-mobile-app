# Job Scan for iOS

A Swift/SwiftUI iPhone and iPad app that scans the englishjobs.* job sites for
roles matching your search, with no server: the phone itself fetches the result
pages, filters them and keeps the reports.

- **Home screen:** **RUN A SEARCH**, a spinner while it runs, the result, and the
  last 10 reports (swipe to delete)
- **Reports:** one per day (`jobs-YYYY-MM-DD.html`, optionally `.md` and `.txt`),
  shown in the app; job links open in Safari; Share button; old reports are
  deleted after `keep_reports_days`
- **Scanning:** for each city, up to `max_pages` result pages, waiting
  `request_delay_seconds` between requests, retrying busy servers (429/5xx), and
  stopping early once results are older than `max_age_days`. Jobs are kept when
  a word in the title starts with one of the keywords
- **Settings:** stored in `config.toml`, editable in the app or the Files app
- **Files:** reports, `config.toml` and `jobscan.log` are in the app's folder in
  the Files app (On My iPhone › Job Scan); the log is also under Settings › Scan log

## Requirements

- A Mac with **Xcode 16 or newer**
- iOS / iPadOS **17** or newer on the device
- An Apple ID added to Xcode (a free one works for your own iPhone; see below)

## Run it

1. Get the code and open `jobscan-mobile-app/JobScan.xcodeproj` in Xcode:
   ```bash
   git clone https://github.com/alexg75/jobscan-mobile-app.git
   open jobscan-mobile-app/JobScan.xcodeproj
   ```
2. Select the **JobScan** target › **Signing & Capabilities**:
   - Team: choose your Apple ID / team.
   - Bundle Identifier: change `dev.jobscan.JobScan` to something unique to you,
     e.g. `com.<yourname>.jobscan`.
3. Pick your iPhone (or a simulator) as the run destination and press **Run** (⌘R).
4. Press **RUN A SEARCH**. The first scan takes about a minute (it waits
   `request_delay_seconds` between requests).

With a free Apple ID, apps installed from Xcode stop opening after 7 days: just
run it from Xcode again. A paid Apple Developer account makes that one year.

> If Xcode can't open the project, regenerate it: `brew install xcodegen`, then
> `cd jobscan-mobile-app && xcodegen generate`.

## Run the tests

The scanning logic and its tests live in a plain Swift package, so they run
without a simulator:

```bash
cd jobscan-mobile-app/JobScanCore

swift test                                  # everything
swift test --filter ConfigFileTests         # one test class
swift test --filter ValidationTests/testRanges   # one test
swift test list                             # list all test names
swift test --parallel                       # run classes in parallel
swift test --enable-code-coverage           # also collect coverage
```

Or open `JobScanCore/Package.swift` in Xcode and press ⌘U.

## Changing what it searches

The settings live in **`config.toml`** in the app's folder (Files app › On My
iPhone › Job Scan). On first launch the app copies in the `config.toml` it ships
with (`JobScan/config.toml`).

**In the app:** Settings › **Edit Settings**. You edit a copy: nothing changes
until you tap **Save**, and Save stays disabled until every setting is valid
(problems are shown in red under the section). Saving rewrites `config.toml`,
with the usual comments; the next scan uses it.

- **Search for**, **title keywords**, **posted** (today, today or yesterday, …),
  **extra languages**
- **Cities**: add, swipe to delete, Edit to reorder. Each city has a name, a job
  site (pick one of the englishjobs.* sites or "Other…") and a location. **Test
  this city** fetches the first results page to check the location is right.
- **Reports**: formats and how many days to keep them
- **Advanced**: pages per city, wait between requests (at least 1 s), stopping at
  old results, extra query parameters

**By hand:** edit `config.toml` in the Files app, or replace it with another copy
(AirDrop, iCloud Drive…). The app re-reads it whenever it comes to the foreground.
If the file has a mistake, the app says which line, uses the default settings
meanwhile, and leaves your file untouched so you can fix it. Settings the app
doesn't know are ignored.

**Sharing:** Settings › **Share config.toml**.

**Reset to Defaults** puts back the `config.toml` that came with the app.

## Layout

```
jobscan-mobile-app/
  JobScan.xcodeproj         Xcode project (app target + local package)
  JobScan-Info.plist        Files app sharing
  project.yml               XcodeGen fallback
  JobScan/                  SwiftUI app
    JobScanApp.swift          app entry
    AppModel.swift            run state, report list
    HomeView.swift            RUN A SEARCH + last 10 searches
    ReportView.swift          report viewer and sharing
    SettingsView.swift        search settings summary, edit/reset, log
    ConfigEditorView.swift    settings editor (draft, Save/Cancel, inline problems)
    CityEditorView.swift      one city: name, site, location, "Test this city"
    config.toml               the default settings, copied to Documents on first launch
  JobScanCore/              Swift package: all the scanning logic
    Sources/JobScanCore/
      ResultsParser.swift       results pages: dates, job blocks, next page, keyword filter
      SiteScanner.swift         search addresses, paging through one city, "Test this city"
      ScanRunner.swift          a full scan: every city, reports, pruning
      ReportRenderer.swift      HTML, Markdown and text reports
      ReportStore.swift         report files, last 10, deleting old ones
      HTTP.swift                URLSession client with retries
      ScanConfig.swift, TOML.swift   config.toml reading and the settings file (ConfigStore)
      TOMLWriter.swift          writes settings back as config.toml
      ConfigValidation.swift    normalized() and validate() for the editor
      ScanLog.swift, Day.swift, Regex.swift, Job.swift
    Tests/JobScanCoreTests/
```
