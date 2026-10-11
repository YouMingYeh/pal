import XCTest
import SwiftUI
@testable import Pal

final class CalendarViewTests: XCTestCase {
    @MainActor func testIdeaAndAgendaRowsExpandInBothAppearancesForAccessibleText() {
        let title = "Coffee and a long catch-up with the weekend crew by the waterfront"
        let idea = HangoutIdea(id: "coffee", title: title, subtitle: "San Francisco · Espresso and pastries", place: nil, sources: [])
        for appearance in [ColorScheme.light, .dark] {
            let normal = UIHostingController(rootView: VStack { HangoutIdeaRow(idea: idea); CalendarAgendaLabel(title: title, detail: "Friday, October 16 at 7:30 PM", emoji: "📅") }.environment(\.colorScheme, appearance).environment(\.dynamicTypeSize, .large))
            let accessible = UIHostingController(rootView: VStack { HangoutIdeaRow(idea: idea); CalendarAgendaLabel(title: title, detail: "Friday, October 16 at 7:30 PM", emoji: "📅") }.environment(\.colorScheme, appearance).environment(\.dynamicTypeSize, .accessibility3))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 1000))
            window.rootViewController = accessible
            window.isHidden = false
            accessible.view.layoutIfNeeded()
            let bounds = CGSize(width: 320, height: 1000)
            let normalSize = normal.sizeThatFits(in: bounds), accessibleSize = accessible.sizeThatFits(in: bounds)
            XCTAssertGreaterThan(accessibleSize.height, normalSize.height, "Long titles wrap instead of being clipped when text grows.")
            XCTAssertLessThanOrEqual(accessibleSize.width, bounds.width + 1)
            window.isHidden = true
        }
        XCTAssertEqual(idea.emoji, "☕️")
    }

    private func calendar(firstWeekday: Int = 1) -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        value.firstWeekday = firstWeekday
        return value
    }
    private func date(_ year: Int, _ month: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    @MainActor func testShortAndLongMonthsHaveStableHeightAndRespectWeekStart() throws {
        let monday = calendar(firstWeekday: 2)
        let february = GroupCalendarView.monthDays(for: date(2026, 2, calendar: monday), calendar: monday)
        let march = GroupCalendarView.monthDays(for: date(2026, 3, calendar: monday), calendar: monday)
        XCTAssertEqual(february.count, 42)
        XCTAssertEqual(march.count, 42, "The agenda must not jump when a month needs an extra week.")
        XCTAssertTrue(february.prefix(6).allSatisfy { $0 == nil }, "February 2026 starts on Sunday, at the end of a Monday-first week.")
        XCTAssertEqual(february.compactMap { $0 }.count, 28)
        XCTAssertEqual(march.compactMap { $0 }.count, 31)
        let sunday = calendar()
        let sundayStart = GroupCalendarView.monthDays(for: date(2026, 2, calendar: sunday), calendar: sunday)
        XCTAssertEqual(sunday.component(.day, from: try XCTUnwrap(sundayStart.first!)), 1)
    }

    @MainActor func testPreferredDayClampsWithoutLosingItAcrossFebruaryAndLeapYears() throws {
        let value = calendar()
        let february = try XCTUnwrap(GroupCalendarView.selection(in: date(2026, 2, calendar: value), preferredDay: 31, calendar: value))
        let march = try XCTUnwrap(GroupCalendarView.selection(in: date(2026, 3, calendar: value), preferredDay: 31, calendar: value))
        let leapFebruary = try XCTUnwrap(GroupCalendarView.selection(in: date(2024, 2, calendar: value), preferredDay: 31, calendar: value))
        XCTAssertEqual(value.component(.day, from: february), 28)
        XCTAssertEqual(value.component(.month, from: february), 2, "Month navigation must not roll January 31 into March.")
        XCTAssertEqual(value.component(.day, from: march), 31, "The preferred day returns after the shorter month.")
        XCTAssertEqual(value.component(.day, from: leapFebruary), 29)
    }

    @MainActor func testSelectedAgendaDateKeepsLocalMidnightAcrossDaylightSaving() throws {
        let value = calendar()
        let march = date(2026, 3, calendar: value)
        let before = try XCTUnwrap(GroupCalendarView.selection(in: march, preferredDay: 8, calendar: value))
        let after = try XCTUnwrap(GroupCalendarView.selection(in: march, preferredDay: 9, calendar: value))
        XCTAssertEqual(value.component(.hour, from: before), 0)
        XCTAssertEqual(value.component(.hour, from: after), 0)
        XCTAssertEqual(after.timeIntervalSince(before), 23 * 3600, "Agenda selection uses calendar days rather than assuming every day is 24 hours.")
    }
}
