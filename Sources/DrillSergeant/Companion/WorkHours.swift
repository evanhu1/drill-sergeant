import Foundation

enum Weekday: String, Codable, CaseIterable, Hashable {
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday

    fileprivate var calendarValue: Int {
        switch self {
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        case .sunday: return 1
        }
    }

    fileprivate var displayName: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    fileprivate init?(calendarValue: Int) {
        guard let weekday = Self.allCases.first(where: {
            $0.calendarValue == calendarValue
        }) else {
            return nil
        }
        self = weekday
    }
}

enum WorkHoursError: Error, Equatable {
    case noDays
    case invalidStartTime
    case invalidEndTime
    case emptyWindow
}

/// One local-time activity window applied to a selected set of weekdays.
struct WorkHours: Codable, Equatable {
    static let standard = WorkHours(
        validatedDays: [.monday, .tuesday, .wednesday, .thursday, .friday],
        startMinutes: 9 * 60,
        endMinutes: 17 * 60
    )

    static let always = WorkHours(
        validatedDays: Weekday.allCases,
        startMinutes: 0,
        endMinutes: 24 * 60
    )

    let days: [Weekday]
    let startTime: String
    let endTime: String

    private let startMinutes: Int
    private let endMinutes: Int

    init(days: [Weekday], startTime: String, endTime: String) throws {
        let uniqueDays = Weekday.allCases.filter(Set(days).contains)
        guard !uniqueDays.isEmpty else { throw WorkHoursError.noDays }
        guard let startMinutes = Self.minutes(
            from: startTime,
            allowsEndOfDay: false
        ) else {
            throw WorkHoursError.invalidStartTime
        }
        guard let endMinutes = Self.minutes(
            from: endTime,
            allowsEndOfDay: true
        ) else {
            throw WorkHoursError.invalidEndTime
        }
        guard startMinutes != endMinutes else { throw WorkHoursError.emptyWindow }

        self.init(
            validatedDays: uniqueDays,
            startMinutes: startMinutes,
            endMinutes: endMinutes
        )
    }

    /// True when `date` falls inside the configured local-time window.
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard let currentWeekday = weekday(for: date, calendar: calendar) else { return false }
        let minute = minuteOfDay(for: date, calendar: calendar)
        let selected = Set(days)

        if endMinutes > startMinutes {
            return selected.contains(currentWeekday)
                && minute >= startMinutes
                && minute < endMinutes
        }

        if selected.contains(currentWeekday), minute >= startMinutes {
            return true
        }
        guard minute < endMinutes,
              let previousDate = calendar.date(byAdding: .day, value: -1, to: date),
              let previousWeekday = weekday(for: previousDate, calendar: calendar) else {
            return false
        }
        return selected.contains(previousWeekday)
    }

    /// Returns the next selected window start at or after `date`.
    func nextStart(onOrAfter date: Date, calendar: Calendar = .current) -> Date? {
        let firstDay = calendar.startOfDay(for: date)
        let selected = Set(days)

        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let weekday = weekday(for: day, calendar: calendar),
                  selected.contains(weekday),
                  let candidate = calendar.date(
                    byAdding: .minute,
                    value: startMinutes,
                    to: day
                  ) else {
                continue
            }
            if candidate >= date {
                return candidate
            }
        }
        return nil
    }

    /// Returns the end of the active window containing `date`.
    func intervalEnd(containing date: Date, calendar: Calendar = .current) -> Date? {
        guard contains(date, calendar: calendar) else { return nil }
        let day = calendar.startOfDay(for: date)
        let minute = minuteOfDay(for: date, calendar: calendar)

        if endMinutes > startMinutes || minute < endMinutes {
            if endMinutes == 24 * 60 {
                return calendar.date(byAdding: .day, value: 1, to: day)
            }
            return calendar.date(byAdding: .minute, value: endMinutes, to: day)
        }
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
            return nil
        }
        return calendar.date(byAdding: .minute, value: endMinutes, to: nextDay)
    }

    var promptDescription: String {
        "\(dayDescription), \(startTime)-\(endTime) local time"
    }

    private var dayDescription: String {
        if days == Weekday.allCases {
            return "Every day"
        }
        if days == [.monday, .tuesday, .wednesday, .thursday, .friday] {
            return "Monday-Friday"
        }
        return days.map(\.displayName).joined(separator: ", ")
    }

    private init(validatedDays: [Weekday], startMinutes: Int, endMinutes: Int) {
        days = validatedDays
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        startTime = Self.timeString(minutes: startMinutes)
        endTime = Self.timeString(minutes: endMinutes)
    }

    private enum CodingKeys: String, CodingKey {
        case days
        case startTime
        case endTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let days = try container.decode([Weekday].self, forKey: .days)
        let startTime = try container.decode(String.self, forKey: .startTime)
        let endTime = try container.decode(String.self, forKey: .endTime)
        try self.init(days: days, startTime: startTime, endTime: endTime)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(days, forKey: .days)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
    }

    private func weekday(for date: Date, calendar: Calendar) -> Weekday? {
        Weekday(calendarValue: calendar.component(.weekday, from: date))
    }

    private func minuteOfDay(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func minutes(from value: String, allowsEndOfDay: Bool) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 2,
              parts[1].count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...59).contains(minute) else {
            return nil
        }
        if hour == 24 {
            return allowsEndOfDay && minute == 0 ? 24 * 60 : nil
        }
        guard (0...23).contains(hour) else { return nil }
        return hour * 60 + minute
    }

    private static func timeString(minutes: Int) -> String {
        if minutes == 24 * 60 { return "24:00" }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
