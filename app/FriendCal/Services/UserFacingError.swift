import Foundation

/// Plain-language copy for every store failure, in one place (design 2.3A, delta C3/O3). Maps the
/// `FC_*` hint first, the SQLSTATE second, the client-side lock errors and the network third, and
/// falls back to a per-action sentence. `details` keeps the raw text for the collapsed "Details" line.
public struct UserFacingError: Error, Equatable {
    public enum Action: Equatable {
        case lock, mark, join, create, load, edit
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
            case "FC_NOT_CREATOR": return UserFacingError(message: "Only \(host) can lock this plan.", details: details)
            case "FC_DATES_FROZEN": return UserFacingError(message: "Can't change the dates once friends have marked times.", details: details)
            case "FC_WINDOW": return UserFacingError(message: "That time doesn't fit inside the plan.", details: details)
            case "FC_NO_RECIPIENTS": return UserFacingError(message: "No one has joined yet.", details: details)
            case "FC_NOT_MEMBER": return UserFacingError(message: "Join this plan before marking times.", details: details)
            default: break
            }
            switch code {
            case "22023": return UserFacingError(message: "Not enough friends are free anymore. Pick another time.", details: details)
            case "40001": return UserFacingError(message: "Availability changed while locking. Try again.", details: details)
            case "55000": return UserFacingError(message: "This plan is already locked.", details: details)
            case "42501": return UserFacingError(message: "Only \(host) can lock this plan.", details: details)
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

    static func generic(_ action: Action) -> String {
        switch action {
        case .lock: return "Couldn't lock. Try again."
        case .mark: return "Couldn't save your availability. Retry."
        case .join, .load: return "Couldn't open this invite."
        case .create: return "Couldn't create the plan. Retry."
        case .edit: return "Couldn't save your changes. Retry."
        }
    }
}
