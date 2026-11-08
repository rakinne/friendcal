import Foundation

/// Plain-language copy for every store failure, in one place (design 2.3A, delta C3/O3). Maps the
/// `FC_*` hint first, the SQLSTATE second, the client-side lock errors and the network third, and
/// falls back to a per-action sentence. `details` keeps the raw text for the collapsed "Details" line.
public struct UserFacingError: Error, Equatable {
    public enum Action: Equatable {
        case lock, mark, join, create, load, edit, deleteAccount, signIn
    }

    public let message: String
    public let details: String?

    public init(message: String, details: String? = nil) {
        self.message = message
        self.details = details
    }

    /// `creatorName` fills "Only Sam can lock this plan." when known.
    public static func map(_ error: Error, action: Action, creatorName: String? = nil) -> UserFacingError {
        if let already = error as? UserFacingError { return already }
        let host = creatorName ?? "the host"
        switch error {
        case let ProposalStoreError.server(code, message, hint):
            let details = [code, message, hint].compactMap { $0 }.joined(separator: " · ")
            switch hint {
            case "FC_QUORUM": return UserFacingError(message: "Not enough friends are free anymore. Pick another time.", details: details)
            case "FC_CHANGED": return UserFacingError(message: "Availability changed while locking. Try again.", details: details)
            case "FC_LOCKED": return UserFacingError(message: "This plan is already locked.", details: details)
            case "FC_CLOSED": return UserFacingError(message: "This plan is closed.", details: details)
            case "FC_NOT_CREATOR": return UserFacingError(message: permissionDenied(action, host), details: details)
            case "FC_NOT_OWNER": return UserFacingError(message: "That hold isn't yours.", details: details)
            case "FC_DATES_FROZEN": return UserFacingError(message: "Can't change the dates once friends have marked times.", details: details)
            case "FC_WINDOW": return UserFacingError(message: "That time doesn't fit inside the plan.", details: details)
            case "FC_NO_RECIPIENTS": return UserFacingError(message: "No one has joined yet.", details: details)
            case "FC_NOT_MEMBER": return UserFacingError(message: "Join this plan before marking times.", details: details)
            // Raised by this wave's SQL (users_auth.sql, join_proposal.sql, rls.sql). The SQL side
            // had briefly invented its own spellings for refusals that already had names here --
            // FC_ALREADY_LOCKED beside FC_LOCKED, FC_BAD_WINDOW beside FC_WINDOW -- which is how two
            // lists of identifiers drift apart without anything failing. The SQL now uses the names
            // below, and `testEveryServerHintIsMapped` pins the set.
            case "FC_NOT_SIGNED_IN": return UserFacingError(message: "Sign in to continue.", details: details)
            case "FC_ACCOUNT_DELETED": return UserFacingError(message: "This account has been deleted.", details: details)
            case "FC_NOT_FOUND": return UserFacingError(message: "This plan is gone.", details: details)
            // Never expected in front of a person: the client tried to write a server-owned field,
            // which is a bug in the client, not something the user did. Worded so that if it ever
            // does surface it reads as a fault rather than as an accusation.
            case "FC_SERVER_OWNED_FIELD": return UserFacingError(message: "Couldn't save that change. Retry.", details: details)
            default: break
            }
            switch code {
            case "22023": return UserFacingError(message: "Not enough friends are free anymore. Pick another time.", details: details)
            case "40001": return UserFacingError(message: "Availability changed while locking. Try again.", details: details)
            case "55000": return UserFacingError(message: "This plan is already locked.", details: details)
            case "42501": return UserFacingError(message: permissionDenied(action, host), details: details)
            default: return UserFacingError(message: generic(action), details: details)
            }
        case ProposalStoreError.notFound:
            return UserFacingError(message: "This plan is gone.", details: String(describing: error))
        case ProposalStoreError.notSignedIn:
            return UserFacingError(message: "Sign in to continue.", details: String(describing: error))
        case ProposalStoreError.heldElsewhere:
            return UserFacingError(message: "You already hold that time for another plan.", details: String(describing: error))
        case let ProposalStoreError.network(text):
            return UserFacingError(message: generic(action), details: text)
        case let lock as ProposalLockError:
            switch lock {
            case .windowTooShort: return UserFacingError(message: "Everyone's free for less than an hour here.", details: lock.errorDescription)
            case .notEnoughCoverage: return UserFacingError(message: "Not enough friends are free anymore. Pick another time.", details: lock.errorDescription)
            case .insufficientRecipients: return UserFacingError(message: "No one has joined yet.", details: lock.errorDescription)
            case .cellNotInWindow: return UserFacingError(message: "That time doesn't fit inside the plan.", details: lock.errorDescription)
            }
        case let url as URLError:
            return UserFacingError(message: generic(action), details: "URLError \(url.code.rawValue): \(url.localizedDescription)")
        default:
            return UserFacingError(message: generic(action), details: String(describing: error))
        }
    }

    /// A 42501 (and its FC_NOT_CREATOR hint) reads as the action that was refused.
    ///
    /// This used to assume every permission refusal was a failed lock or edit, so it answered
    /// "Only the host can lock this plan." That is simply false for the two actions this wave adds:
    /// deleting your own account and signing in have no host, and a person who just tapped
    /// "Delete account" being told the host owns it is nonsense. Both route past the creator wording
    /// entirely rather than being special-cased at each call site.
    static func permissionDenied(_ action: Action, _ host: String) -> String {
        switch action {
        case .deleteAccount: return "Couldn't delete your account. Sign in and try again."
        case .signIn: return "Couldn't sign you in. Try again."
        case .edit: return "Only \(host) can edit this plan."
        case .lock, .mark, .join, .create, .load: return "Only \(host) can lock this plan."
        }
    }

    /// Kept as the name the creator-only wording is reached by, for call sites that mean exactly that.
    static func creatorOnly(_ action: Action, _ host: String) -> String {
        action == .edit ? "Only \(host) can edit this plan." : "Only \(host) can lock this plan."
    }

    static func generic(_ action: Action) -> String {
        switch action {
        case .lock: return "Couldn't lock. Try again."
        case .mark: return "Couldn't save your availability. Retry."
        case .join, .load: return "Couldn't open this invite."
        case .create: return "Couldn't create the plan. Retry."
        case .edit: return "Couldn't save your changes. Retry."
        case .deleteAccount: return "Couldn't delete your account. Retry."
        case .signIn: return "Couldn't sign you in. Try again."
        }
    }
}
