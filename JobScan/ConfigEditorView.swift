import SwiftUI
import JobScanCore

/// Edits a copy of the settings. Nothing changes until Save, and Save is only
/// possible when the settings pass `ScanConfig.validate()`.
struct ConfigEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let original: ScanConfig
    @State private var draft: ScanConfig
    @State private var path: [UUID] = []
    @State private var showAdvanced = false
    @State private var confirmDiscard = false
    @State private var saveError: String?

    init(config: ScanConfig) {
        original = config.normalized()
        _draft = State(initialValue: config)
    }

    private var issues: [ConfigIssue] { draft.normalized().validate() }
    private var hasChanges: Bool { draft.normalized() != original }

    private func messages(_ field: ConfigIssue.Field) -> [String] {
        issues.filter { $0.field == field }.map(\.message)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                searchSection
                keywordsSection
                languagesSection
                citiesSection
                reportsSection
                advancedSection
            }
            .navigationTitle("Edit settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                cityEditor(id)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!hasChanges || !issues.isEmpty)
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .alert("Couldn't save the settings", isPresented: saveErrorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
        .interactiveDismissDisabled(hasChanges)
    }

    private var saveErrorShown: Binding<Bool> {
        Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    }

    private func save() {
        do {
            try model.updateConfig(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    // MARK: Sections

    private var searchSection: some View {
        Section {
            TextField("e.g. java solution architect", text: $draft.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Search for")
        } footer: {
            FieldFooter(help: "Sent to every site, like typing it in the site's search box.",
                        problems: messages(.query))
        }
    }

    private var keywordsSection: some View {
        Section {
            StringListEditor(items: $draft.keywords, placeholder: "keyword", addTitle: "Add keyword")
            Stepper(value: $draft.maxAgeDays, in: ScanConfig.maxAgeDaysRange) {
                LabeledContent("Posted", value: SettingsView.postedText(draft.maxAgeDays))
            }
        } header: {
            Text("Keep jobs")
        } footer: {
            FieldFooter(help: "A job is kept when a word in its title starts with one of the keywords: \"lead\" also matches \"Leader\", \"tech\" matches \"Technical\".",
                        problems: messages(.keywords) + messages(.maxAgeDays))
        }
    }

    private var languagesSection: some View {
        Section {
            StringListEditor(items: $draft.includeLanguages, placeholder: "e.g. italian", addTitle: "Add language")
        } header: {
            Text("Extra languages")
        } footer: {
            FieldFooter(help: "Also include jobs that need English plus one of these languages.",
                        problems: messages(.includeLanguages))
        }
    }

    private var citiesSection: some View {
        Section {
            ForEach(draft.searches) { search in
                NavigationLink(value: search.id) {
                    CityRow(search: search, hasProblem: !messages(.search(search.id)).isEmpty)
                }
            }
            .onDelete { draft.searches.remove(atOffsets: $0) }
            .onMove { draft.searches.move(fromOffsets: $0, toOffset: $1) }
            Button {
                let city = SearchTarget(name: "", site: SearchTarget.knownSites[0].url, location: "")
                draft.searches.append(city)
                path.append(city.id)
            } label: {
                Label("Add city", systemImage: "plus.circle.fill")
            }
        } header: {
            HStack {
                Text("Cities")
                Spacer()
                EditButton()
                    .font(.footnote)
                    .textCase(nil)
            }
        } footer: {
            let cityProblems = draft.searches.contains { !messages(.search($0.id)).isEmpty }
            FieldFooter(help: "Swipe to delete. Tap Edit to reorder; reports list the cities in this order.",
                        problems: messages(.searches) + (cityProblems ? ["Fix the cities marked with ⚠︎."] : []))
        }
    }

    private var reportsSection: some View {
        Section {
            ForEach(ReportFormat.allCases, id: \.self) { format in
                Toggle(format.displayName, isOn: formatBinding(format))
            }
            Stepper(value: $draft.keepReportsDays, in: ScanConfig.keepReportsDaysRange) {
                LabeledContent("Keep reports", value: "\(draft.keepReportsDays) day\(draft.keepReportsDays == 1 ? "" : "s")")
            }
        } header: {
            Text("Reports")
        } footer: {
            FieldFooter(help: "The app shows the first format; all of them can be shared.",
                        problems: messages(.reportFormats) + messages(.keepReportsDays))
        }
    }

    private func formatBinding(_ format: ReportFormat) -> Binding<Bool> {
        Binding(
            get: { draft.reportFormats.contains(format) },
            set: { on in
                var set = Set(draft.reportFormats)
                if on { set.insert(format) } else { set.remove(format) }
                draft.reportFormats = ReportFormat.allCases.filter { set.contains($0) }
            }
        )
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                Stepper(value: $draft.maxPages, in: ScanConfig.maxPagesRange) {
                    LabeledContent("Pages per city", value: "up to \(draft.maxPages)")
                }
                Stepper(value: $draft.requestDelaySeconds, in: ScanConfig.requestDelayRange, step: 1) {
                    LabeledContent("Wait between requests",
                                   value: "\(draft.requestDelaySeconds.formatted(.number.precision(.fractionLength(0...1)))) s")
                }
                Toggle("Stop at old results", isOn: $draft.resultsSortedByDate)
                ParamListEditor(params: $draft.extraParams)
            }
        } footer: {
            let problems = messages(.maxPages) + messages(.requestDelay) + messages(.extraParams)
            FieldFooter(help: showAdvanced ? "\"Stop at old results\" stops paging at the first page where every job is too old (needs sort = date, as results then come newest first). Extra parameters are added to every search address." : "",
                        problems: problems)
        }
    }

    // MARK: City editor

    @ViewBuilder
    private func cityEditor(_ id: UUID) -> some View {
        if let index = draft.searches.firstIndex(where: { $0.id == id }) {
            CityEditorView(search: cityBinding(id, fallback: draft.searches[index]),
                           config: draft.normalized(),
                           problems: messages(.search(id)))
        } else {
            ContentUnavailableView("City removed", systemImage: "mappin.slash")
        }
    }

    /// A binding to one city that stays safe if the list changes underneath it.
    private func cityBinding(_ id: UUID, fallback: SearchTarget) -> Binding<SearchTarget> {
        Binding(
            get: { draft.searches.first { $0.id == id } ?? fallback },
            set: { updated in
                if let i = draft.searches.firstIndex(where: { $0.id == id }) { draft.searches[i] = updated }
            }
        )
    }
}

// MARK: - Small building blocks

/// Help text plus any problems (in red) under a section.
struct FieldFooter: View {
    let help: String
    let problems: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if !help.isEmpty { Text(help) }
        }
    }
}

private struct CityRow: View {
    let search: SearchTarget
    let hasProblem: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(search.name.isEmpty ? "New city" : search.name)
                    .foregroundStyle(search.name.isEmpty ? .secondary : .primary)
                Text("\(URL(string: search.site)?.host ?? search.site) · \(search.location.isEmpty ? "no location" : search.location)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if hasProblem {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Needs attention")
            }
        }
    }
}

/// Rows of text fields with swipe-to-delete and an Add button.
struct StringListEditor: View {
    @Binding var items: [String]
    let placeholder: String
    let addTitle: String

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, _ in
            TextField(placeholder, text: item(index))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .onDelete { items.remove(atOffsets: $0) }
        Button {
            items.append("")
        } label: {
            Label(addTitle, systemImage: "plus.circle.fill")
        }
    }

    /// Index-safe binding: a row being deleted never reads past the end of the list.
    private func item(_ index: Int) -> Binding<String> {
        Binding(
            get: { items.indices.contains(index) ? items[index] : "" },
            set: { if items.indices.contains(index) { items[index] = $0 } }
        )
    }
}

/// Name = value rows for `extra_params`.
struct ParamListEditor: View {
    @Binding var params: [QueryParam]

    var body: some View {
        ForEach(Array(params.enumerated()), id: \.offset) { index, _ in
            HStack {
                TextField("name", text: field(index, \.name))
                Text("=").foregroundStyle(.secondary)
                TextField("value", text: field(index, \.value))
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .onDelete { params.remove(atOffsets: $0) }
        Button {
            params.append(QueryParam(name: "", value: ""))
        } label: {
            Label("Add extra parameter", systemImage: "plus.circle.fill")
        }
    }

    private func field(_ index: Int, _ keyPath: WritableKeyPath<QueryParam, String>) -> Binding<String> {
        Binding(
            get: { params.indices.contains(index) ? params[index][keyPath: keyPath] : "" },
            set: { if params.indices.contains(index) { params[index][keyPath: keyPath] = $0 } }
        )
    }
}
