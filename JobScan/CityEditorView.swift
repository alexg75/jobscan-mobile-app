import SwiftUI
import JobScanCore

/// One city: its name, job site and location slug, plus a quick test against the site.
struct CityEditorView: View {
    @Binding var search: SearchTarget
    /// The settings being edited (used by the test: query, keywords, languages…).
    let config: ScanConfig
    let problems: [String]

    @State private var useOtherSite: Bool
    @State private var test: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case running
        case finished(message: String, ok: Bool)
    }

    private static let otherSite = "other"

    init(search: Binding<SearchTarget>, config: ScanConfig, problems: [String]) {
        _search = search
        self.config = config
        self.problems = problems
        let site = search.wrappedValue.normalized().site
        _useOtherSite = State(initialValue: !SearchTarget.knownSites.contains { $0.url == site })
    }

    var body: some View {
        Form {
            Section {
                TextField("e.g. Amsterdam (NL)", text: $search.name)
            } header: {
                Text("Name")
            } footer: {
                Text("Used as the heading for this city in the reports.")
            }

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
                Text("Fetches the first page of results with the search text, keywords and languages you're editing.")
            }
        }
        .navigationTitle(search.name.trimmingCharacters(in: .whitespaces).isEmpty ? "New city" : search.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: search) { _, _ in
            test = .idle  // an old result no longer applies
        }
    }

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

    private var canTest: Bool {
        let s = search.normalized()
        return SearchTarget.isValidSite(s.site) && !s.location.isEmpty
            && !config.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func runTest() async {
        test = .running
        let scanner = SiteScanner(client: RetryingHTTPClient(base: URLSessionHTTPClient(), retries: 1))
        do {
            let result = try await scanner.probe(config: config, search: search.normalized(), today: Day(Date()))
            if result.found == 0 {
                test = .finished(message: "The site returned no jobs for this search. Check the location.", ok: false)
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
