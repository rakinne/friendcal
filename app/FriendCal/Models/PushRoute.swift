import Foundation

/// Where a tapped push leads. The Edge Function puts push_outbox.data under the `fc` key of the
/// APNs payload; this is the only place that reads it.
///
/// The payload arrives from outside the app, so it is parsed strictly: an unknown kind, a missing
/// id or a malformed UUID is no route at all (the app simply opens), never a guess.
public enum PushRoute: Equatable, Sendable {
    /// A poke for the current user. Tapping the push acknowledges it.
    case poke(UUID)
    /// Someone joined a plan the current user hosts.
    case tagAlong(proposalID: UUID)

    public static let payloadKey = "fc"

    public static func parse(_ userInfo: [AnyHashable: Any]) -> PushRoute? {
        guard let data = userInfo[payloadKey] as? [String: Any], let kind = data["kind"] as? String else { return nil }
        func id(_ key: String) -> UUID? { (data[key] as? String).flatMap(UUID.init(uuidString:)) }
        switch kind {
        case "poke": return id("poke_id").map(PushRoute.poke)
        case "tag_along": return id("proposal_id").map { .tagAlong(proposalID: $0) }
        default: return nil
        }
    }

    /// `-FriendCalPushTap poke/<uuid>` or `tagalong/<uuid>`: a UI test's stand-in for tapping a push.
    public init?(launchArgument: String) {
        let parts = launchArgument.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "poke": self = .poke(id)
        case "tagalong": self = .tagAlong(proposalID: id)
        default: return nil
        }
    }
}
