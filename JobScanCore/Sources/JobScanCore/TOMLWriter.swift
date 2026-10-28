import Foundation

extension ScanConfig {
    /// The settings as a config.toml file, with a comment explaining each setting.
    public func tomlString() -> String {
        var out: [String] = [
            "# Job Scan settings.",
            "# Saved by the app (Settings > Edit Settings); you can also edit it by hand.",
            "",
            "# Search text sent to every site (becomes /in/{location}/{query})",
            "query = \(TOMLFormat.string(query))",
            "",
            "# Keep jobs whose TITLE has a word starting with one of these (case-insensitive).",
            "# \"lead\" also matches \"Leader\"/\"Leading\", \"tech\" matches \"Technical\"/\"Technology\".",
            "keywords = \(TOMLFormat.array(keywords))",
            "",
            "# Keep jobs posted today or within the last N days.",
            "max_age_days = \(maxAgeDays)",
            "",
            "# Also include jobs that need English plus one of these languages.",
            "include_languages = \(TOMLFormat.array(includeLanguages))",
            "",
            "# Pagination and politeness",
            "max_pages = \(maxPages)",
            "request_delay_seconds = \(TOMLFormat.number(requestDelaySeconds))",
            "",
            "# Results are sorted newest-first (sort=date, the site's \"newest\" link), so the",
            "# scan stops at the first page where every job is older than max_age_days.",
            "results_sorted_by_date = \(resultsSortedByDate)",
            "extra_params = \(TOMLFormat.inlineTable(extraParams))",
            "",
            "# Report files to write each run: \"html\", \"md\" (Markdown), \"txt\" (plain text) - any mix,",
            "# and how many days to keep them.",
            "report_formats = \(TOMLFormat.array(reportFormats.map(\.rawValue)))",
            "keep_reports_days = \(keepReportsDays)",
        ]
        for search in searches {
            out += [
                "",
                "[[searches]]",
                "name = \(TOMLFormat.string(search.name))",
                "site = \(TOMLFormat.string(search.site))",
                "location = \(TOMLFormat.string(search.location))",
            ]
        }
        return out.joined(separator: "\n") + "\n"
    }
}

enum TOMLFormat {
    /// A basic string: "…" with \\, \" and control characters escaped.
    static func string(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func array(_ items: [String]) -> String {
        "[" + items.map { string($0) }.joined(separator: ", ") + "]"
    }

    /// A bare key when possible (letters, digits, _ and -), otherwise quoted.
    static func key(_ k: String) -> String {
        let bare = !k.isEmpty && k.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }
        return bare ? k : string(k)
    }

    static func inlineTable(_ params: [QueryParam]) -> String {
        if params.isEmpty { return "{}" }
        return "{ " + params.map { "\(key($0.name)) = \(string($0.value))" }.joined(separator: ", ") + " }"
    }

    /// 3 -> "3", 1.5 -> "1.5"
    static func number(_ d: Double) -> String {
        if d.rounded() == d && abs(d) < 1e15 { return String(Int(d)) }
        return String(d)
    }
}
