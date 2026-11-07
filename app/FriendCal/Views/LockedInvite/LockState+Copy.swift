import Foundation
import FriendCalCore

/// The invite's copy per state (issue #5 design 1.1A, 2.1A, 3.1A). One localized format per
/// sentence, with inflection for the count; VoiceOver reads the same strings.
extension LockState {
    /// The caption on the card scrim; nil once locked (the card shows the date and window instead).
    func caption(creatorName: String?, isCreator: Bool) -> String? {
        switch self {
        case .inviteFriends:
            return "No one has joined yet"
        case .requesting:
            if isQuorumReached {
                return isCreator ? "Enough friends overlap" : "Enough friends overlap. Waiting for \(creatorName ?? "the host") to lock."
            }
            return remaining == 1 ? "Locked until 1 more friend overlaps" : "Locked until \(remaining) more friends overlap"
        case .locked:
            return nil
        }
    }

    /// "1 of 8 joined", "7 of 10 overlap so far", "8 of 10 are in".
    func progress(headcount: Int) -> String {
        switch self {
        case .inviteFriends(let expected):
            return "1 of \(max(expected, 1)) joined"
        case .requesting(let have, _, let total, _, _):
            return "\(have) of \(total) overlap so far"
        case .locked(_, let attendees, _):
            return "\(attendees.count) of \(headcount) are in"
        }
    }

    /// The teal secondary link; nil once locked.
    func linkTitle(hasMyHolds: Bool) -> String? {
        switch self {
        case .inviteFriends: return "Mark your availability"
        case .requesting: return hasMyHolds ? "Update your availability" : "Unlock with availability"
        case .locked: return nil
        }
    }

    /// The one coral control: "Invite friends" for the creator alone, "Lock Sat afternoon" for the
    /// creator at quorum; nil otherwise.
    func primaryTitle(isCreator: Bool, calendar: Calendar) -> String? {
        switch self {
        case .inviteFriends:
            return isCreator ? "Invite friends" : nil
        case .requesting(_, _, _, _, let best):
            guard isCreator, isQuorumReached, let best else { return nil }
            return "Lock \(DateText.dayPart(day: best.day, daypart: best.daypart, calendar: calendar, locale: .current))"
        case .locked:
            return nil
        }
    }

    /// Below a locked card: "You're in", "Locked before you joined.", "Locked without you. You weren't free then."
    func attendanceLine(for user: UUID?) -> String? {
        guard case .locked(_, let attendees, let late) = self, let user else { return nil }
        if attendees.contains(user) { return "You're in" }
        if late.contains(user) { return "Locked before you joined." }
        return "Locked without you. You weren't free then."
    }

    func isAttendee(_ user: UUID?) -> Bool {
        guard case .locked(_, let attendees, _) = self, let user else { return false }
        return attendees.contains(user)
    }

    /// Nav title (design 7.1B): "Locked Invite" while requesting, "Invite" once locked.
    var navTitle: String { isLocked ? "Invite" : "Locked Invite" }
}
