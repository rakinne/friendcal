import Foundation

/// `friendcal://proposal/<uuid>` (issue #5 D3). `scheme` is the single Swift constant; a unit test
/// asserts CFBundleURLTypes in the app bundle matches it (red flag 8: no hand-synced list).
/// Universal links and a not-installed fallback are a TODO (D16).
public enum DeepLink: Equatable {
    case proposal(UUID)

    public static let scheme = "friendcal"
    public static let proposalHost = "proposal"

    /// nil for another scheme, another host, a missing or malformed id, or extra path components.
    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == proposalHost else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let id = UUID(uuidString: parts[0]) else { return nil }
        return .proposal(id)
    }

    public var url: URL {
        switch self {
        case .proposal(let id): return URL(string: "\(Self.scheme)://\(Self.proposalHost)/\(id.uuidString.lowercased())")!
        }
    }
}
