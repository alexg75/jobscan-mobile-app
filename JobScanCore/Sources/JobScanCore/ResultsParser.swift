import Foundation

/// Reads the Markdown results pages (`?format=markdown`) and filters jobs.
public enum ResultsParser {

    // MARK: Dates

    static let months: [String: Int] = {
        let names: [[String]] = [
            ["january", "jan"], ["february", "feb"], ["march", "mar"], ["april", "apr"],
            ["may"], ["june", "jun"], ["july", "jul"], ["august", "aug"],
            ["september", "sep", "sept"], ["october", "oct"], ["november", "nov"],
            ["december", "dec"],
        ]
        var table: [String: Int] = [:]
        for (index, group) in names.enumerated() {
            for name in group { table[name] = index + 1 }
        }
        return table
    }()

    static let monthDay = Rx(#"^(?<month>[A-Za-z]+)\.?\s+(?<day>\d{1,2})(?:,?\s+(?<year>\d{4}))?$"#)
    static let dayMonth = Rx(#"^(?<day>\d{1,2})\s+(?<month>[A-Za-z]+)\.?(?:,?\s+(?<year>\d{4}))?$"#)
    static let relative = Rx(#"^(?<n>\d+)\s+(?<unit>minute|hour|day|week)s?\s+ago$"#, .caseInsensitive)

    /// Turns "October 26", "yesterday", "3 days ago" … into a day (or nil).
    public static func parsePosted(_ text: String, today: Day) -> Day? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "today" || t == "just now" || t == "new" { return today }
        if t == "yesterday" { return today.adding(days: -1) }

        if let m = relative.match(t), let nText = m["n"], let n = Int(nText), let unit = m["unit"]?.lowercased() {
            if unit == "minute" || unit == "hour" { return today }
            return today.adding(days: -n * (unit == "week" ? 7 : 1))
        }

        guard let m = monthDay.match(t) ?? dayMonth.match(t),
              let monthName = m["month"], let month = months[monthName],
              let dayText = m["day"], let day = Int(dayText) else { return nil }
        let yearText = m["year"]
        let year = yearText.flatMap { Int($0) } ?? today.year
        guard var posted = Day(year: year, month: month, day: day) else { return nil }
        // No year on the site: a date "in the future" belongs to last year (Dec 30 seen on Jan 2).
        if yearText == nil && posted > today.adding(days: 1) {
            guard let lastYear = Day(year: year - 1, month: month, day: day) else { return nil }
            posted = lastYear
        }
        return posted
    }

    // MARK: Results pages

    /// A job title is a line that is just a Markdown link (optionally as a heading or bullet).
    static let linkLine = Rx(#"^\s*(?:#+\s*|[-*]\s+)?\[(?<title>(?:\\.|[^\]\\])+)\]\((?<url>[^)\s]+)\)\s*$"#)
    static let bullet = Rx(#"^\s*[-*]\s+(?<text>.+?)\s*$"#)
    static let escaped = Rx(#"\\(.)"#)
    static let headingMarks = Rx(#"^\s*#+\s*|\s*#+\s*$"#)
    static let spaces = Rx(#"\s+"#)
    static let nextPageLink = Rx(#"\[next page\]"#, .caseInsensitive)

    static func unescape(_ s: String) -> String {
        escaped.replace(s, with: "$1").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops Markdown heading markers ("### Title", "Title ###") and extra spaces.
    static func cleanTitle(_ s: String) -> String {
        let noMarks = headingMarks.replace(unescape(s), with: "")
        return spaces.replace(noMarks, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finds job blocks: a link line followed by a bullet list that contains a date.
    public static func parseResults(_ markdown: String, today: Day) -> [Job] {
        // Splitting on Characters keeps "\r\n" together as one line break.
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).map(String.init)
        var jobs: [Job] = []
        var i = 0
        while i < lines.count {
            guard let link = linkLine.match(lines[i]), let rawTitle = link["title"], let url = link["url"] else {
                i += 1
                continue
            }

            var bullets: [String] = []
            var j = i + 1
            while j < lines.count {
                let line = lines[j]
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !bullets.isEmpty { break }
                    j += 1
                    continue
                }
                guard let b = bullet.match(line), let text = b["text"] else { break }
                bullets.append(unescape(text))
                j += 1
            }

            guard let dateIndex = bullets.firstIndex(where: { parsePosted($0, today: today) != nil }),
                  let posted = parsePosted(bullets[dateIndex], today: today) else {
                i += 1  // not a job (navigation link etc.)
                continue
            }

            let info = Array(bullets[..<dateIndex])
            var location = ""
            if info.count > 1 {
                location = String(info[1].drop(while: { $0 == "," || $0 == " " }))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            jobs.append(Job(title: cleanTitle(rawTitle),
                            company: info.first ?? "",
                            location: location,
                            posted: posted,
                            url: url))
            i = j
        }
        return jobs
    }

    public static func hasNextPage(_ markdown: String, page: Int) -> Bool {
        markdown.contains("page=\(page + 1)") || nextPageLink.matches(markdown)
    }

    /// Keeps jobs posted on or after `cutoff` whose title matches, newest first, without duplicates.
    public static func select(_ jobs: [Job], matcher: KeywordMatcher, cutoff: Day) -> [Job] {
        // Stable newest-first sort (Swift's sort is not guaranteed to keep equal items in order).
        let ordered = jobs.enumerated().sorted { a, b in
            a.element.posted != b.element.posted ? a.element.posted > b.element.posted : a.offset < b.offset
        }.map { $0.element }

        struct Key: Hashable { let title: String; let company: String; let posted: Day }
        var seen = Set<Key>()
        var out: [Job] = []
        for job in ordered {
            let key = Key(title: job.title.lowercased(), company: job.company.lowercased(), posted: job.posted)
            if seen.contains(key) || job.posted < cutoff || !matcher.matches(job.title) { continue }
            seen.insert(key)
            out.append(job)
        }
        return out
    }
}

/// Matches a keyword at the start of a word: "lead" matches "Lead"/"Leader",
/// "tech" matches "Technical", but not "Misleading" or "Biotechnician".
public struct KeywordMatcher: @unchecked Sendable {
    let rx: Rx

    public init(keywords: [String]) {
        let alternatives = keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        rx = Rx(#"\b(?:"# + alternatives + ")", .caseInsensitive)
    }

    public func matches(_ title: String) -> Bool { rx.matches(title) }
}
