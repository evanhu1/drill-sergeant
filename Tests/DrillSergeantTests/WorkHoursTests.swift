import XCTest
@testable import DrillSergeant

final class WorkHoursTests: XCTestCase {
    func testStandardHoursAreWeekdaysNineToFive() throws {
        let hours = WorkHours.standard

        XCTAssertEqual(
            hours.days,
            [.monday, .tuesday, .wednesday, .thursday, .friday]
        )
        XCTAssertEqual(hours.startTime, "09:00")
        XCTAssertEqual(hours.endTime, "17:00")
        XCTAssertFalse(hours.contains(try date("2026-09-07 08:59"), calendar: calendar))
        XCTAssertTrue(hours.contains(try date("2026-09-07 09:00"), calendar: calendar))
        XCTAssertTrue(hours.contains(try date("2026-09-07 16:59"), calendar: calendar))
        XCTAssertFalse(hours.contains(try date("2026-09-07 17:00"), calendar: calendar))
        XCTAssertFalse(hours.contains(try date("2026-09-06 12:00"), calendar: calendar))
    }

    func testOvernightWindowUsesSelectedStartDay() throws {
        let hours = try WorkHours(
            days: [.friday],
            startTime: "22:00",
            endTime: "02:00"
        )

        XCTAssertTrue(hours.contains(try date("2026-09-04 23:00"), calendar: calendar))
        XCTAssertTrue(hours.contains(try date("2026-09-05 01:59"), calendar: calendar))
        XCTAssertFalse(hours.contains(try date("2026-09-05 02:00"), calendar: calendar))
        XCTAssertFalse(hours.contains(try date("2026-09-05 23:00"), calendar: calendar))
        XCTAssertEqual(
            hours.intervalEnd(
                containing: try date("2026-09-04 23:00"),
                calendar: calendar
            ),
            try date("2026-09-05 02:00")
        )
    }

    func testEndOfDayStaysAtLocalMidnightAcrossDaylightSavingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let sunday = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))
        )

        let end = try XCTUnwrap(WorkHours.always.intervalEnd(
            containing: sunday,
            calendar: calendar
        ))

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: end),
            DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 0)
        )
    }

    func testFindsNextWindowStartAcrossWeekend() throws {
        XCTAssertEqual(
            WorkHours.standard.nextStart(
                onOrAfter: try date("2026-09-04 17:01"),
                calendar: calendar
            ),
            try date("2026-09-07 09:00")
        )
    }

    func testValidatesAndCanonicalizesToolValues() throws {
        let hours = try WorkHours(
            days: [.friday, .monday, .friday],
            startTime: "08:30",
            endTime: "24:00"
        )

        XCTAssertEqual(hours.days, [.monday, .friday])
        XCTAssertEqual(hours.promptDescription, "Monday, Friday, 08:30-24:00 local time")
        XCTAssertThrowsError(
            try WorkHours(days: [], startTime: "09:00", endTime: "17:00")
        )
        XCTAssertThrowsError(
            try WorkHours(days: [.monday], startTime: "9:00", endTime: "17:00")
        )
        XCTAssertThrowsError(
            try WorkHours(days: [.monday], startTime: "09:00", endTime: "09:00")
        )
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: value))
    }
}
