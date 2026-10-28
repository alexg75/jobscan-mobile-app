import SwiftUI
import JobScanCore

/// The main screen:
/// a RUN A SEARCH button with a spinner and result message, and the last 10 reports.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                runSection
                reportsSection
                if let problem = model.configProblem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Job Scan")
            .navigationDestination(for: ReportEntry.self) { entry in
                ReportView(entry: entry)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environment(model)
            }
            .refreshable {
                model.reloadReports()
            }
        }
    }

    private var runSection: some View {
        Section {
            Button {
                Task { await model.runScan() }
            } label: {
                Text("RUN A SEARCH")
                    .font(.headline)
                    .tracking(0.6)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

            if model.isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching… this usually takes under a minute.")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if let last = model.lastRun {
                ResultMessage(last: last)
            }
        } header: {
            Text(model.subtitle)
                .textCase(nil)
        }
    }

    private var reportsSection: some View {
        Section("Last 10 searches") {
            if model.reports.isEmpty {
                Text("No searches yet. Press RUN A SEARCH.")
                    .italic()
                    .foregroundStyle(.secondary)
            }
            ForEach(model.reports) { entry in
                NavigationLink(value: entry) {
                    ReportRow(entry: entry, isNew: entry.day == model.newReportDay)
                }
            }
            .onDelete { offsets in
                model.deleteReports(at: offsets)
            }
        }
    }
}

/// "Search finished at 09:27. A new result is available." (green) or the problem (red).
private struct ResultMessage: View {
    let last: AppModel.LastRun

    var body: some View {
        let time = last.finishedAt.formatted(date: .omitted, time: .shortened)
        VStack(alignment: .leading, spacing: 6) {
            if last.ok {
                Text("Search finished at \(time). A new result is available: \(last.message).")
            } else {
                Text("The search finished with a problem: \(last.message).")
            }
            if let report = last.report {
                NavigationLink(value: report) {
                    Text("Open \(report.label)")
                        .fontWeight(.semibold)
                }
            }
        }
        .foregroundStyle(last.ok ? Color.green : Color.red)
        .listRowBackground((last.ok ? Color.green : Color.red).opacity(0.12))
    }
}

private struct ReportRow: View {
    let entry: ReportEntry
    let isNew: Bool

    var body: some View {
        HStack {
            Text(entry.label)
                .fontWeight(.medium)
            if isNew {
                Text("NEW")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(Color.green)
            }
            Spacer()
            Text("updated \(Self.updatedText(entry.updated))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    static func updatedText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
