import SwiftUI
import UIKit
import UniformTypeIdentifiers
import JobScanCore

/// The search settings (with Edit, Reset, Import and Export), and the log.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var importing = false
    @State private var importResult: ImportResult?

    private struct ImportResult {
        let ok: Bool
        let message: String
    }

    /// .toml files, plus plain text in case the file has no recognised type.
    private static let tomlTypes: [UTType] = [UTType(filenameExtension: "toml"), UTType.plainText, UTType.text].compactMap { $0 }

    var body: some View {
        NavigationStack {
            Form {
                searchSection
                actionsSection
                configFileSection
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
        }
    }

    private var importResultShown: Binding<Bool> {
        Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } })
    }

    private var importTitle: String {
        importResult?.ok == true ? "Settings imported" : "Couldn't import the settings"
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            try model.importConfig(from: url)
            importResult = ImportResult(ok: true, message: "The settings from \(url.lastPathComponent) are now in use.")
        } catch {
            importResult = ImportResult(ok: false, message: error.localizedDescription)
        }
    }

    // MARK: Search settings

    private var searchSection: some View {
        let c = model.config
        return Section {
            LabeledContent("Search for", value: c.query.isEmpty ? "not set" : c.query)
            LabeledContent("Title keywords", value: c.keywords.isEmpty ? "none" : c.keywords.joined(separator: ", "))
            LabeledContent("Posted", value: Self.postedText(c.maxAgeDays))
            LabeledContent("Extra languages", value: c.includeLanguages.isEmpty ? "none" : c.includeLanguages.joined(separator: ", "))
            LabeledContent("Pages per city", value: "up to \(c.maxPages)")
            LabeledContent("Report formats", value: c.reportFormats.map(\.rawValue).joined(separator: ", "))
            LabeledContent("Keep reports", value: "\(c.keepReportsDays) days")
            if c.searches.isEmpty {
                LabeledContent("Cities", value: "none")
            }
            ForEach(c.searches) { search in
                LabeledContent(search.name, value: "\(URL(string: search.site)?.host ?? search.site) · \(search.location)")
            }
        } header: {
            HStack {
                Text("Search settings")
                Spacer()
                Text(!model.hasSavedSettings ? "Empty" : model.isCustomConfig ? "Customised" : "Default")
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
        } footer: {
            if model.isRunning {
                Text("Settings can be changed when the current search finishes.")
            } else {
                Text("Saved in the app's database on this phone.")
            }
        }
    }

    /// The Files app's name for local storage: "On My iPhone" or "On My iPad".
    static var onMyDevice: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
    }

    static func postedText(_ maxAgeDays: Int) -> String {
        switch maxAgeDays {
        case ..<1: return "today"
        case 1: return "today or yesterday"
        default: return "in the last \(maxAgeDays + 1) days"
        }
    }

    // MARK: config.toml

    private var configFileSection: some View {
        Section {
            Button {
                importing = true
            } label: {
                Label("Import config.toml", systemImage: "square.and.arrow.down")
            }
            .disabled(model.isRunning)
            if let file = model.exportConfigFile() {
                ShareLink(item: file) {
                    Label("Export config.toml", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("config.toml")
        } footer: {
            Text("Export the settings as a config.toml file to back them up, share them, or edit them elsewhere. Importing a file checks it first, then replaces the current settings.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.tomlTypes) { result in
            importFile(result)
        }
        .alert(Text(importTitle), isPresented: importResultShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importResult?.message ?? "")
        }
    }

    // MARK: Files

    private var filesSection: some View {
        Section {
            NavigationLink("Scan log") {
                LogView(log: model.log)
            }
        } header: {
            Text("Files")
        } footer: {
            Text("Reports and anglo-job-scan.log are also in the Files app, under \(Self.onMyDevice) › AngloRadar.")
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
