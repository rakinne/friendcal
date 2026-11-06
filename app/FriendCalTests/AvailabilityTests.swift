import XCTest
@testable import FriendCalCore

final class AvailabilityTests: XCTestCase {
    func testTapFreeCreatesSoftHold() {
        let svc = AvailabilityService()
        let res = svc.tapFreeSlot(userID: UUID(), range: DateRange(Date.now...Date.now.addingTimeInterval(7200)), proposalID: UUID(), expiresAt: Date().addingTimeInterval(86400))
        if case .softHold(let slot) = res {
            XCTAssertEqual(slot.state, .softHold)
        } else { XCTFail("expected softHold") }
    }

    func testSoftHoldExpires() {
        let svc = AvailabilityService()
        let expired = AvailabilitySlot(userID: UUID(), range: DateRange(Date.now...Date.now), sourceProposalID: nil, state: .softHold, expiresAt: Date().addingTimeInterval(-1))
        XCTAssertTrue(expired.isExpired)
        XCTAssertEqual(svc.expireStaleHolds(slots: [expired]).count, 0)
    }

    func testOverBlockCollisionBusyBlocksSecondTap() {
        let svc = AvailabilityService()
        let user = UUID()
        let busy = AvailabilitySlot(userID: user, range: DateRange(Date.now...Date.now.addingTimeInterval(7200)), sourceProposalID: nil, state: .busy)
        let res = svc.tapFreeSlot(userID: user, range: DateRange(Date.now...Date.now.addingTimeInterval(3600)), proposalID: UUID(), expiresAt: nil, existingSlots: [busy])
        if case .alreadyHeld = res { } else { XCTFail("busy should block softHold") }
    }

    func testPromoteOnLockMovesWinnerAndExpiresLosers() {
        let svc = AvailabilityService()
        let proposalID = UUID()
        let day1 = Date.now
        let day2 = Calendar.current.date(byAdding: .day, value: 1, to: Date.now)!
        let s1 = AvailabilitySlot(userID: UUID(), range: DateRange(lower: day1, upper: day1.addingTimeInterval(7200)), sourceProposalID: proposalID, state: .softHold, expiresAt: Date().addingTimeInterval(86400))
        let s2 = AvailabilitySlot(userID: UUID(), range: DateRange(lower: day2, upper: day2.addingTimeInterval(7200)), sourceProposalID: proposalID, state: .softHold, expiresAt: Date().addingTimeInterval(86400))
        let lockedWindow = DateRange(lower: day1, upper: day1.addingTimeInterval(3600))
        let (promoted, expired) = svc.promoteToBusy(window: lockedWindow, proposalID: proposalID, recipientIDs: [s1.userID, s2.userID], slots: [s1, s2], now: Date())
        XCTAssertEqual(promoted.count, 1)
        XCTAssertEqual(promoted.first?.userID, s1.userID)
        // D4: the winner's hold is cleared too; its BusyBlock replaces it.
        XCTAssertEqual(Set(expired), [s1.id, s2.id])
    }

    /// D3 + D12: an Evening lock on a shared 18:00-19:30 window promotes the 18:00-20:00 hold, and
    /// expires a hold that only partly covers the window, another day's hold, and a non-recipient's.
    func testEveningLockPromotesSlotsCoveringCommonWindow() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))! }
        let svc = AvailabilityService()
        let proposalID = UUID()
        let friend = UUID(), late = UUID(), other = UUID(), stranger = UUID()
        let expires = Date().addingTimeInterval(86400)
        func hold(_ user: UUID, _ from: Date, _ to: Date) -> AvailabilitySlot {
            AvailabilitySlot(userID: user, range: DateRange(lower: from, upper: to), sourceProposalID: proposalID, state: .softHold, expiresAt: expires)
        }
        let winner = hold(friend, at(14, 18), at(14, 20))
        let partial = hold(late, at(14, 19), at(14, 21))
        let otherDay = hold(other, at(15, 18), at(15, 20))
        let notInvited = hold(stranger, at(14, 18), at(14, 20))
        let window = DateRange(lower: at(14, 18), upper: at(14, 19, 30))
        let (promoted, expired) = svc.promoteToBusy(window: window, proposalID: proposalID, recipientIDs: [friend, late, other], slots: [winner, partial, otherDay, notInvited], now: Date())
        XCTAssertEqual(promoted.map(\.userID), [friend])
        // D4: the block is the locked window, not the whole 18:00-20:00 hold; every hold is cleared.
        XCTAssertEqual(promoted.first?.range, window)
        XCTAssertEqual(Set(expired), [winner.id, partial.id, otherDay.id, notInvited.id])
    }

    // MARK: Promotion matches the heatmap's quorum rule (review D4)

    private static var nyc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }
    private static func at(_ h: Int, _ m: Int = 0) -> Date { nyc.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: h, minute: m))! }
    private static func hold(_ user: UUID, _ proposalID: UUID, _ from: Date, _ to: Date, expires: Date = AvailabilityTests.at(23)) -> AvailabilitySlot {
        AvailabilitySlot(userID: user, range: DateRange(lower: from, upper: to), sourceProposalID: proposalID, state: .softHold, expiresAt: expires)
    }

    /// Value: protects=a recipient whose touching holds together cover the common window (so the
    /// heatmap counted them toward quorum) is promoted; fails_when=promotion checks each hold alone;
    /// why_new=existing tests use one hold per user; seam=none; no_claim=server write (pure service).
    func testAdjacentHoldsThatFormTheWindowPromote() {
        let pid = UUID(), friend = UUID()
        let a = Self.hold(friend, pid, Self.at(18), Self.at(19))
        let b = Self.hold(friend, pid, Self.at(19), Self.at(20))
        let window = DateRange(lower: Self.at(18), upper: Self.at(19, 30))
        let (promoted, _) = AvailabilityService().promoteToBusy(window: window, proposalID: pid, recipientIDs: [friend], slots: [a, b], now: Self.at(8))
        XCTAssertEqual(promoted.map(\.userID), [friend])
        XCTAssertEqual(promoted.first?.range, window)
    }

    /// Value: protects=the BusyBlock covers the locked common window, not the whole hold (D3, no
    /// over-blocking); fails_when=promotion copies slot.range; why_new=old tests asserted the hold
    /// range; seam=none; no_claim=server write (pure service).
    func testPromotionBlocksOnlyTheCommonWindow() {
        let pid = UUID(), friend = UUID()
        let allDay = Self.hold(friend, pid, Self.at(9), Self.at(21))
        let window = DateRange(lower: Self.at(10), upper: Self.at(11))
        let (promoted, expired) = AvailabilityService().promoteToBusy(window: window, proposalID: pid, recipientIDs: [friend], slots: [allDay], now: Self.at(8))
        XCTAssertEqual(promoted.map(\.range), [window])
        XCTAssertEqual(expired, [allDay.id], "the settled hold is cleared once its BusyBlock exists")
    }

    /// Value: protects=one BusyBlock per recipient even with overlapping holds or a duplicated
    /// recipient ID; fails_when=one block is emitted per covering slot; why_new=no test has two
    /// covering holds; seam=none; no_claim=the DB exclusion constraint (schema.sql).
    func testOneBusyBlockPerRecipient() {
        let pid = UUID(), friend = UUID()
        let wide = Self.hold(friend, pid, Self.at(17), Self.at(21))
        let narrow = Self.hold(friend, pid, Self.at(18), Self.at(20))
        let window = DateRange(lower: Self.at(18), upper: Self.at(19))
        let (promoted, _) = AvailabilityService().promoteToBusy(window: window, proposalID: pid, recipientIDs: [friend, friend], slots: [wide, narrow], now: Self.at(8))
        XCTAssertEqual(promoted.count, 1)
    }

    /// Value: protects=promotion drops a hold that expires exactly at the injected now, like the
    /// heatmap (expiresAt > now); fails_when=promotion reads the wall clock or uses <=; why_new=
    /// promotion took no now before; seam=none; no_claim=server clock skew.
    func testPromotionUsesInjectedNowForExpiry() {
        let pid = UUID(), friend = UUID()
        let lockTime = Self.at(17)
        let lapsed = Self.hold(friend, pid, Self.at(18), Self.at(20), expires: lockTime)
        let window = DateRange(lower: Self.at(18), upper: Self.at(19))
        let (promoted, expired) = AvailabilityService().promoteToBusy(window: window, proposalID: pid, recipientIDs: [friend], slots: [lapsed], now: lockTime)
        XCTAssertTrue(promoted.isEmpty)
        XCTAssertEqual(expired, [lapsed.id])
        let (stillHeld, _) = AvailabilityService().promoteToBusy(window: window, proposalID: pid, recipientIDs: [friend], slots: [lapsed], now: lockTime.addingTimeInterval(-1))
        XCTAssertEqual(stillHeld.count, 1)
    }
}
