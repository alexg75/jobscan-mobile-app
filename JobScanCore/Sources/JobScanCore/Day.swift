import Foundation

/// A calendar day with no time or time zone.
///
/// Arithmetic uses plain day numbers (days since 1970-01-01), so adding or
/// subtracting days never trips over daylight-saving changes.
public struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Returns nil for impossible dates such as 30 February.
    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= Day.daysInMonth(year: year, month: month) else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local calendar day of `date`.
    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(ordinal: Day.ordinal(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1))
    }

    /// Parses "2026-10-27".
    public init?(iso text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Days since 1970-01-01 (proleptic Gregorian calendar).
    public var ordinal: Int { Day.ordinal(year: year, month: month, day: day) }

    public init(ordinal: Int) {
        // Howard Hinnant's civil_from_days
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.year = m <= 2 ? y + 1 : y
        self.month = m
        self.day = d
    }

    public func adding(days: Int) -> Day { Day(ordinal: ordinal + days) }

    /// Whole days from `other` to `self`.
    public func days(since other: Day) -> Int { ordinal - other.ordinal }

    public static func < (lhs: Day, rhs: Day) -> Bool { lhs.ordinal < rhs.ordinal }

    /// "2026-10-27"
    public var description: String {
        "\(Day.pad(year, 4))-\(Day.pad(month, 2))-\(Day.pad(day, 2))"
    }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    public static func isLeapYear(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    static func ordinal(year: Int, month: Int, day: Int) -> Int {
        // Howard Hinnant's days_from_civil
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}

extension Day: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let day = Day(iso: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Not a YYYY-MM-DD date: \(text)"))
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// "2026-10-27 15:04" in the calendar's time zone.
func timestamp(_ date: Date, calendar: Calendar, seconds: Bool = false) -> String {
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    var s = "\(Day.pad(c.year ?? 0, 4))-\(Day.pad(c.month ?? 0, 2))-\(Day.pad(c.day ?? 0, 2)) "
        + "\(Day.pad(c.hour ?? 0, 2)):\(Day.pad(c.minute ?? 0, 2))"
    if seconds { s += ":\(Day.pad(c.second ?? 0, 2))" }
    return s
}
