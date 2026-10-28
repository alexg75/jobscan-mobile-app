import Foundation

/// Writes the report in HTML, Markdown or plain text.
public enum ReportRenderer {

    public static func render(_ format: ReportFormat, results: [CityResult], config: ScanConfig,
                              now: Date, cutoff: Day, calendar: Calendar = .current) -> String {
        switch format {
        case .html: return html(results: results, config: config, now: now, cutoff: cutoff, calendar: calendar)
        case .md: return markdown(results: results, config: config, now: now, cutoff: cutoff, calendar: calendar)
        case .txt: return text(results: results, config: config, now: now, cutoff: cutoff, calendar: calendar)
        }
    }

    static func matches(_ n: Int) -> String { n == 1 ? "match" : "matches" }

    static func total(_ results: [CityResult]) -> Int { results.reduce(0) { $0 + $1.jobs.count } }

    // MARK: Plain text

    public static func text(results: [CityResult], config: ScanConfig, now: Date, cutoff: Day,
                            calendar: Calendar = .current) -> String {
        let langs = config.includeLanguages
        var posted = "Posted on or after: \(cutoff)"
        if !langs.isEmpty { posted += " | Extra languages: \(langs.joined(separator: ", "))" }
        var out = [
            "Job scan - \(timestamp(now, calendar: calendar))",
            "Query: \"\(config.query)\" | Title keywords: \(config.keywords.joined(separator: ", "))",
            posted,
            "Total matches: \(total(results))",
            "",
        ]
        for city in results {
            out.append("== \(city.name) - \(city.jobs.count) \(matches(city.jobs.count)) ==")
            if let error = city.error { out.append("   ERROR: \(error)") }
            for j in city.jobs {
                out.append("* \(j.title)")
                let details = [j.company.isEmpty ? "" : "Company: \(j.company)",
                               j.location.isEmpty ? "" : "Location: \(j.location)",
                               "Posted: \(j.posted)"]
                out.append("  " + details.filter { !$0.isEmpty }.joined(separator: " | "))
                out.append("  \(j.url)")
            }
            if city.jobs.isEmpty && city.error == nil { out.append("   No matching jobs.") }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    // MARK: Markdown

    static func mdCell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func markdown(results: [CityResult], config: ScanConfig, now: Date, cutoff: Day,
                                calendar: Calendar = .current) -> String {
        let langs = config.includeLanguages
        let n = total(results)
        var meta = "Query: **\(mdCell(config.query))** · Title keywords: \(config.keywords.joined(separator: ", ")) · "
        meta += "Posted on or after: \(cutoff)"
        if !langs.isEmpty { meta += " · Extra languages: \(langs.joined(separator: ", "))" }
        meta += " · **\(n) matches**"
        var out = ["# Job scan - \(timestamp(now, calendar: calendar))", "", meta, ""]
        for city in results {
            out.append("## \(city.name) - \(city.jobs.count) \(matches(city.jobs.count))")
            out.append("")
            if let error = city.error { out += ["> ⚠️ Error: \(mdCell(error))", ""] }
            if !city.jobs.isEmpty {
                out += ["| Title | Company | Location | Posted |",
                        "| ----- | ------- | -------- | ------ |"]
                for j in city.jobs {
                    let title = mdCell(j.title).replacingOccurrences(of: "[", with: "\\[")
                        .replacingOccurrences(of: "]", with: "\\]")
                    out.append("| [\(title)](<\(j.url)>) | \(mdCell(j.company)) | \(mdCell(j.location)) | \(j.posted) |")
                }
                out.append("")
            } else if city.error == nil {
                out += ["_No matching jobs._", ""]
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: HTML

    /// Escapes &, <, >, " and ' for HTML.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#x27;"
            default: out.append(ch)
            }
        }
        return out
    }

    static let style = """

    :root { --bg:#fff; --fg:#1d1d1f; --muted:#6e6e73; --line:#e5e5ea; --head:#f5f5f7; --link:#0a58ca; --warn:#b3261e; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#161618; --fg:#ececf1; --muted:#9a9aa2; --line:#2c2c30; --head:#1f1f23; --link:#7ab4ff; --warn:#ff8a80; }
    }
    * { box-sizing: border-box; }
    body { margin:0; padding:24px 16px; background:var(--bg); color:var(--fg);
           font:15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    main { max-width:1000px; margin:0 auto; }
    h1 { font-size:22px; margin:0 0 4px; }
    .meta { color:var(--muted); margin:0 0 24px; font-size:14px; }
    h2 { font-size:17px; margin:28px 0 8px; display:flex; gap:8px; align-items:baseline; }
    .count { color:var(--muted); font-weight:400; font-size:14px; }
    .wrap { overflow-x:auto; }
    table { width:100%; border-collapse:collapse; }
    th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
    th { background:var(--head); font-size:13px; color:var(--muted); font-weight:600; }
    td.date { white-space:nowrap; font-variant-numeric:tabular-nums; }
    a { color:var(--link); text-decoration:none; } a:hover { text-decoration:underline; }
    .none { color:var(--muted); font-style:italic; margin:4px 0; }
    .error { color:var(--warn); margin:4px 0; }

    """

    public static func html(results: [CityResult], config: ScanConfig, now: Date, cutoff: Day,
                            calendar: Calendar = .current) -> String {
        let e = escape
        let n = total(results)
        let langs = config.includeLanguages
        let stamp = timestamp(now, calendar: calendar)
        var meta = "Query: <strong>\(e(config.query))</strong> · Title keywords: \(e(config.keywords.joined(separator: ", ")))"
        meta += " · Posted on or after \(cutoff)"
        if !langs.isEmpty { meta += " · Extra languages: \(e(langs.joined(separator: ", ")))" }
        meta += " · <strong>\(n) \(matches(n))</strong>"
        var out = ["<!doctype html>", "<html lang=\"en\">", "<head>", "<meta charset=\"utf-8\">",
                   "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
                   "<title>Job scan \(Day(now, calendar: calendar))</title>", "<style>\(style)</style>", "</head>",
                   "<body><main>", "<h1>Job scan - \(stamp)</h1>", "<p class=\"meta\">\(meta)</p>"]
        for city in results {
            out.append("<h2>\(e(city.name)) <span class=\"count\">\(city.jobs.count) \(matches(city.jobs.count))</span></h2>")
            if let error = city.error { out.append("<p class=\"error\">Error: \(e(error))</p>") }
            if !city.jobs.isEmpty {
                out.append("<div class=\"wrap\"><table><thead><tr><th>Title</th><th>Company</th>"
                           + "<th>Location</th><th>Posted</th></tr></thead><tbody>")
                for j in city.jobs {
                    out.append("<tr><td><a href=\"\(e(j.url))\" target=\"_blank\" rel=\"noopener\">\(e(j.title))</a></td>"
                               + "<td>\(e(j.company))</td><td>\(e(j.location))</td>"
                               + "<td class=\"date\">\(j.posted)</td></tr>")
                }
                out.append("</tbody></table></div>")
            } else if city.error == nil {
                out.append("<p class=\"none\">No matching jobs.</p>")
            }
        }
        out.append("</main></body></html>")
        return out.joined(separator: "\n")
    }
}
