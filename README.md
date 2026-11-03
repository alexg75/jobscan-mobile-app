# Anglo Job Radar (iOS)

A Swift/SwiftUI iPhone and iPad app that scans the englishjobs.* job sites for
roles matching your search, with no server: the phone itself fetches the result
pages, filters them and keeps the reports.

- **Home screen:** **RUN A SEARCH**; while it runs, the city being searched, how many
  cities are done (e.g. 2/5) and a **STOP** button, which ends the search and saves a
  report with the results so far; then the result, and the last 10 reports (swipe
  to delete)
- **Reports:** one per day (`jobs-YYYY-MM-DD.html`, optionally `.md` and `.txt`),
  shown in the app; job links open in Safari; Share button; old reports are
  deleted after `keep_reports_days`
- **Scanning:** for each city, up to `max_pages` result pages, waiting
  `request_delay_seconds` between requests, and stopping early once results are
  older than `max_age_days`. Busy servers (429/5xx) and network errors are retried
  after 1, 2 and 3 seconds; a page that still fails ends that city's search (no
  further pages), and the report shows the error in place of the match count. A
  request gives up after 20 seconds, and if a site can't be reached its other cities
  are skipped. Jobs are kept when
  a word in the title starts with one of the keywords
- **Settings:** stored in a database on the phone, editable in the app; import and
  export as `config.toml`
- **Files:** reports and `anglo-job-scan.log` are in the app's folder in
  the Files app (On My iPhone / On My iPad › AngloRadar); the log is also under Settings › Scan log

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

The settings are stored in a **SwiftData database on the phone** (no server). A new
install starts with an **empty** database: nothing is searched until you enter your
settings and Save (or import a config.toml). The `config.toml` the app ships with
(`JobScan/config.toml`) is not loaded into the settings; it is only used if the database
can't be opened. On the first launch a copy of it is put in the app's folder in the Files
app (On My iPhone / On My iPad › AngloRadar), as an example to edit and import with
**Import config.toml**. A file already there is left alone, and a deleted copy is not put back.

**In the app:** Settings › **Edit Settings**. You edit a copy: nothing changes
until you tap **Save**, and Save stays disabled until every setting is valid
(problems are shown in red under the section). The next scan uses the new settings.

- **Search for**, **title keywords**, **posted** (today, today or yesterday, …),
  **extra languages**
- **Cities**: add, swipe to delete, Edit to reorder. Each city has a job site (pick
  one of the englishjobs.* sites or "Other…") and a location. Its name is made from
  those and can't be typed: location `amsterdam` on englishjobsearch.nl is
  "Amsterdam (NL)". Two cities can't have the same name: on Save, the one lower in
  the list replaces the other (keeping the other's place). **Test this city** fetches
  the first results page to check the location is right. Imported config.toml files
  don't need a `name`; any name in them is replaced the same way.
- **Reports**: formats and how many days to keep them
- **Advanced**: pages per city, wait between requests (at least 1 s), stopping at
  old results, extra query parameters

**config.toml files:** Settings › **Export config.toml** shares the current settings
as a file (to back them up or edit them elsewhere); **Import config.toml** reads one
from the Files app, checks it, and replaces the current settings. Settings the app
doesn't know are ignored.

**Erase Settings Database** (at the bottom of Settings › Edit Settings, after a
confirmation) deletes everything in the settings database. The settings are then
empty (no search text, keywords, languages or cities; the defaults are *not* brought
back) and RUN A SEARCH is disabled until you enter new settings and Save.

**Upgrading:** on its first launch this version imports the `config.toml` the app
kept in its folder until now (instead of the bundled one), and renames the file
`config.imported.toml`. If the database can't be opened, the app keeps its settings
in `config.toml` instead and says so in Settings.

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
    SettingsView.swift        search settings summary, edit, import/export, log
    ConfigEditorView.swift    settings editor (draft, Save/Cancel, inline problems, erase database)
    CityEditorView.swift      one city: site, location, its generated name, "Test this city"
    config.toml               the default settings
  JobScanCore/              Swift package: all the scanning logic
    Sources/JobScanCore/
      ResultsParser.swift       results pages: dates, job blocks, next page, keyword filter
      SiteScanner.swift         search addresses, paging through one city, "Test this city"
      ScanRunner.swift          a full scan: every city, reports, pruning
      ReportRenderer.swift      HTML, Markdown and text reports
      ReportStore.swift         report files, last 10, deleting old ones
      HTTP.swift                URLSession client with time limits, retries, error labels
      SettingsStore.swift       where settings are kept (database, or config.toml as fallback)
      SettingsDatabase.swift    the SwiftData settings database
      ScanConfig.swift, TOML.swift   settings type, config.toml reading, ConfigStore
      TOMLWriter.swift          writes settings back as config.toml
      ConfigValidation.swift    normalized() and validate() for the editor
      ScanLog.swift, Day.swift, Regex.swift, Job.swift
    Tests/JobScanCoreTests/
```
