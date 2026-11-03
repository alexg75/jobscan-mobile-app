import SwiftUI
import JobScanCore

/// One city: its job site and location slug, plus a quick test against the site.
/// The city's name is made from those two and can't be typed.
struct CityEditorView: View {
    @Binding var search: SearchTarget
    /// The settings being edited (used by the test: query, keywords, languages…).
    let config: ScanConfig
    let problems: [String]
    /// Set when another city in the list gets the same name (only one is kept on Save).
    let duplicateNote: String?

    @State private var useOtherSite: Bool
    @State private var test: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case running
        case finished(message: String, ok: Bool)
    }

    private static let otherSite = "other"

    init(search: Binding<SearchTarget>, config: ScanConfig, problems: [String], duplicateNote: String? = nil) {
        _search = search
        self.config = config
        self.problems = problems
        self.duplicateNote = duplicateNote
        let site = search.wrappedValue.normalized().site
        _useOtherSite = State(initialValue: !SearchTarget.knownSites.contains { $0.url == site })
    }

    var body: some View {
        Form {
            Section {
                Picker("Site", selection: siteSelection) {
                    ForEach(SearchTarget.knownSites) { site in
                        Text("\(site.host) (\(site.country))").tag(site.url)
                    }
                    Text("Other…").tag(Self.otherSite)
                }
                if useOtherSite {
                    TextField("https://…", text: $search.site)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Job site")
            }

            Section {
                TextField("e.g. amsterdam", text: $search.location)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Location")
            } footer: {
                Text("The city part of the site's own link for that city, e.g. s-gravenhage in englishjobsearch.nl/in/s-gravenhage. The site's /llms.txt page lists them.")
            }

            Section {
                LabeledContent("City", value: cityName.isEmpty ? "Enter a location" : cityName)
                    .foregroundStyle(cityName.isEmpty ? .secondary : .primary)
                if let duplicateNote {
                    Label(duplicateNote, systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Made from the location and the job site's country, e.g. amsterdam on englishjobsearch.nl is Amsterdam (NL). Used as the heading for this city in the reports.")
            }

            if !problems.isEmpty {
                Section {
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        Text("Test this city")
                        if test == .running {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(test == .running || !canTest)

                if case .finished(let message, let ok) = test {
                    Label(message, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(ok ? Color.green : Color.red)
                }
            } footer: {
                Text("Needs only the job site and location. Fetches the first page of results, using the search text, keywords and languages you're editing if they're filled in.")
            }
        }
        .navigationTitle(cityName.isEmpty ? "New city" : cityName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: search) { _, _ in
            test = .idle  // an old result no longer applies
        }
    }

    private var cityName: String { search.normalized().name }

    private var siteSelection: Binding<String> {
        Binding(
            get: { useOtherSite ? Self.otherSite : search.normalized().site },
            set: { choice in
                if choice == Self.otherSite {
                    useOtherSite = true
                } else {
                    useOtherSite = false
                    search.site = choice
                }
            }
        )
    }

    /// Only the job site and location are needed; the search text and keywords are optional.
    private var canTest: Bool {
        let s = search.normalized()
        return SearchTarget.isValidSite(s.site) && !s.location.isEmpty
    }

    private var hasSearchSetUp: Bool {
        !config.query.trimmingCharacters(in: .whitespaces).isEmpty && !config.keywords.isEmpty
    }

    private func runTest() async {
        test = .running
        let scanner = SiteScanner(client: RetryingHTTPClient(base: URLSessionHTTPClient(), delays: [1]))
        do {
            let result = try await scanner.probe(config: config, search: search.normalized(), today: Day(Date()))
            if result.found == 0 {
                test = .finished(message: "The site returned no jobs for this search. Check the location.", ok: false)
            } else if !hasSearchSetUp {
                test = .finished(message: "The location works: found \(result.found) jobs on the first page. Enter the search text and keywords to see how many match.", ok: true)
            } else {
                test = .finished(message: "Found \(result.found) jobs on the first page; \(result.matching) match your keywords and date range.", ok: true)
            }
        } catch let error as HTTPStatusError where error.statusCode == 404 {
            test = .finished(message: "The site doesn't recognise this location (404). Check the spelling.", ok: false)
        } catch {
            test = .finished(message: error.localizedDescription, ok: false)
        }
    }
}
