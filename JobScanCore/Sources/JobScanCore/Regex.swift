import Foundation

/// Small wrapper around NSRegularExpression (ICU), with named groups.
/// Works on iOS, macOS and Linux.
struct Rx: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        // The patterns are constants written in this file set; a typo is a programming error.
        // swiftlint:disable:next force_try
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    init(compiled: NSRegularExpression) { regex = compiled }

    /// First match anywhere in `text` (patterns that must match at the start begin with `^`).
    func match(_ text: String) -> RxMatch? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return RxMatch(result: result, text: text)
    }

    func matches(_ text: String) -> Bool { match(text) != nil }

    /// Replaces every match; groups are written `$1` in the template.
    func replace(_ text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

struct RxMatch {
    let result: NSTextCheckingResult
    let text: String

    /// A named group's text, or nil if the group did not take part in the match.
    subscript(name: String) -> String? {
        let r = result.range(withName: name)
        guard r.location != NSNotFound, let range = Range(r, in: text) else { return nil }
        return String(text[range])
    }

    /// A numbered group's text (1 = first group).
    subscript(index: Int) -> String? {
        guard index < result.numberOfRanges else { return nil }
        let r = result.range(at: index)
        guard r.location != NSNotFound, let range = Range(r, in: text) else { return nil }
        return String(text[range])
    }
}
