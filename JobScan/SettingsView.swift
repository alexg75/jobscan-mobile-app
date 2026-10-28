import SwiftUI
import JobScanCore

/// The search settings (with Edit and Reset), and the log.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmReset = false
    @State private var resetError: String?

    var body: some View {
        NavigationStack {
            Form {
                searchSection
                actionsSection
                filesSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $editing) {
                ConfigEditorView(config: model.config)
                    .environment(model)
            }
            .confirmationDialog("Reset the search settings?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset to Defaults", role: .destructive) { reset() }
            } message: {
                Text("config.toml is replaced by the one that came with the app.")
            }
            .alert("Couldn't reset the settings", isPresented: resetErrorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resetError ?? "")
            }
        }
    }

    private var resetErrorShown: Binding<Bool> {
        Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })
    }

    private func reset() {
        do {
            try model.resetConfig()
        } catch {
            resetError = error.localizedDescription
        }
    }

    // MARK: Search settings

    private var searchSection: some View {
        let c = model.config
        return Section {
            LabeledContent("Search for", value: c.query)
            LabeledContent("Title keywords", value: c.keywords.joined(separator: ", "))
            LabeledContent("Posted", value: Self.postedText(c.maxAgeDays))
            LabeledContent("Extra languages", value: c.includeLanguages.isEmpty ? "none" : c.includeLanguages.joined(separator: ", "))
            LabeledContent("Pages per city", value: "up to \(c.maxPages)")
            LabeledContent("Report formats", value: c.reportFormats.map(\.rawValue).joined(separator: ", "))
            LabeledContent("Keep reports", value: "\(c.keepReportsDays) days")
            ForEach(c.searches) { search in
                LabeledContent(search.name, value: "\(URL(string: search.site)?.host ?? search.site) · \(search.location)")
            }
        } header: {
            HStack {
                Text("Search settings")
                Spacer()
                Text(model.isCustomConfig ? "Customised" : "Default")
                    .textCase(nil)
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                editing = true
            } label: {
                Label("Edit Settings", systemImage: "slider.horizontal.3")
            }
            .disabled(model.isRunning)
            if model.isCustomConfig {
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
                .disabled(model.isRunning)
            }
        } footer: {
            if model.isRunning {
                Text("Settings can be changed when the current search finishes.")
            } else {
                Text("Saved in config.toml, in the Files app under On My iPhone › Job Scan: you can share it, or edit it there.")
            }
        }
    }

    static func postedText(_ maxAgeDays: Int) -> String {
        switch maxAgeDays {
        case ..<1: return "today"
        case 1: return "today or yesterday"
        default: return "in the last \(maxAgeDays + 1) days"
        }
    }

    // MARK: Files

    private var filesSection: some View {
        Section {
            NavigationLink("Scan log") {
                LogView(log: model.log)
            }
            ShareLink(item: model.configStore.fileURL) {
                Label("Share config.toml", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Files")
        } footer: {
            Text("Reports, config.toml and jobscan.log are also in the Files app, under On My iPhone › Job Scan.")
        }
    }
}

struct LogView: View {
    let log: ScanLog
    @State private var text = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "Nothing logged yet." : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("end")
            }
            .onAppear {
                text = log.tail(maxLines: 400)
                DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .navigationTitle("Scan log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: log.fileURL)
            }
        }
    }
}
