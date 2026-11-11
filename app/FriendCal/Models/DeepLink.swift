import Foundation

/// Every link the app opens (issue #5 D3; add-a-friend spec section 5):
///
///     friendcal://proposal/<uuid>?t=<title>          https://friendcal.app/p/<uuid>?t=<title>
///     friendcal://friend/<token>?n=<name>            https://friendcal.app/f/<token>?n=<name>
///
/// `scheme` is the single Swift constant; a unit test asserts CFBundleURLTypes in the app bundle matches
/// it (red flag 8: no hand-synced list). The https forms parse today and are what the app SHARES once
/// the site ships (`useWebLinks`, one constant).
public enum DeepLink: Equatable, Sendable {
    /// A plan, and optionally the title the sender saw.
    ///
    /// The title rides along so the invite screen has something to show while it joins. Under D6's
    /// row scoping a link holder cannot read the plan until they have joined it, so without this the
    /// screen has nothing but a spinner at the one moment someone is deciding whether to bother.
    ///
    /// It is a HINT, never a fact. It arrives from outside the app -- a pasted URL, a forwarded
    /// message, anyone's edit -- so it is attacker-controlled text and is treated as such: sanitized
    /// once here at the boundary, and replaced by the server's own title the moment `join_proposal`
    /// answers. Nothing is authorized on its basis.
    case proposal(UUID, title: String? = nil)

    /// A friend's personal link: its 22-character token and the name hint the sender's app put in.
    /// The hint is shown on the sign-in pill and the web landing page ONLY; the Accept screen names
    /// the inviter from the server's answer, never from the URL (R5).
    case friend(String, name: String? = nil)

    public static let scheme = "friendcal"
    public static let proposalHost = "proposal"
    public static let friendHost = "friend"
    /// Web forms: `https://friendcal.app/f/<token>` and `/p/<uuid>`, host and path matched exactly.
    public static let webHost = "friendcal.app"
    public static let friendWebPath = "f"
    public static let proposalWebPath = "p"
    /// Flips to true in the pull request that ships the static site, so every shared link moves
    /// from the custom scheme to https at once.
    public static let useWebLinks = true
    /// Query item carrying a friend's name hint.
    public static let nameKey = "n"
    /// The longest name hint accepted. A first name, not a payload.
    public static let maxNameLength = 40
    /// Query item carrying the title hint. Short because it goes in a message people see.
    public static let titleKey = "t"

    /// The longest title hint accepted. Anything longer is a payload, not a plan name, and would
    /// either blow up the invite layout or push the real content off screen.
    public static let maxTitleLength = 80

    /// nil for another scheme or host, a malformed id or token, or extra path components.
    ///
    /// Read through `URLComponents` rather than by splitting the string: percent-encoding,
    /// `+`-for-space and repeated query keys all have rules, and hand-parsing them is how a title
    /// like "Dad's 60th" arrives as "Dad%27s 60th" or how a second `?t=` silently wins.
    public static func parse(_ url: URL) -> DeepLink? {
        let parts = url.pathComponents.filter { $0 != "/" }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // First occurrence wins, deliberately and explicitly: a URL with two `t=` items is
        // malformed, and picking the first is at least stable rather than depending on parse order.
        func query(_ key: String) -> String? { components?.queryItems?.first { $0.name == key }?.value }

        switch url.scheme?.lowercased() {
        case scheme:
            switch url.host?.lowercased() {
            case proposalHost:
                guard parts.count == 1, let id = UUID(uuidString: parts[0]) else { return nil }
                return .proposal(id, title: sanitizedTitle(query(titleKey)))
            case friendHost:
                guard parts.count == 1, FriendToken.isValid(parts[0]) else { return nil }
                return .friend(parts[0], name: sanitizedTitle(query(nameKey), cap: maxNameLength))
            default:
                return nil
            }
        case "https":
            // Host `friendcal.app` exactly, no port and no credentials, and a path of exactly two parts.
            guard url.host?.lowercased() == webHost, url.port == nil, url.user == nil, url.password == nil, parts.count == 2 else { return nil }
            switch parts[0] {
            case proposalWebPath:
                guard let id = UUID(uuidString: parts[1]) else { return nil }
                return .proposal(id, title: sanitizedTitle(query(titleKey)))
            case friendWebPath:
                guard FriendToken.isValid(parts[1]) else { return nil }
                return .friend(parts[1], name: sanitizedTitle(query(nameKey), cap: maxNameLength))
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// The one place a title hint from outside the app is cleaned up.
    ///
    /// Sanitizing at the boundary rather than at each use is the point: a screen that receives a
    /// `DeepLink` can render its title without knowing where it came from, because there is no path
    /// by which an unsanitized one exists. Doing it per-view would mean every new view is a new
    /// chance to forget.
    ///
    /// What it removes, and why each one:
    ///   - control characters and newlines: a multi-line "title" breaks the invite card's layout and
    ///     can push the real content out of view
    ///   - bidirectional overrides (U+202A-U+202E, U+2066-U+2069): these reorder surrounding text,
    ///     so a crafted title can make the rest of the screen read as something else entirely
    ///   - zero-width characters: invisible padding, used to make two different titles look identical
    ///   - leading and trailing whitespace, then a length cap
    /// An empty result becomes nil, so "no usable title" has exactly one representation.
    ///
    /// `cap` is 80 for a plan title and `maxNameLength` (40) for a friend's name hint.
    public static func sanitizedTitle(_ raw: String?, cap: Int = maxTitleLength) -> String? {
        guard let raw else { return nil }
        let stripped = raw.unicodeScalars.filter { scalar in
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            switch scalar.value {
            case 0x200B...0x200F,      // zero-width space/joiners, LTR/RTL marks
                 0x202A...0x202E,      // bidi embedding and override
                 0x2060...0x206F,      // word joiner, invisible operators, bidi isolates
                 0xFEFF:               // zero-width no-break space (BOM)
                return false
            default:
                return true
            }
        }
        let text = String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(cap))
    }

    /// nil for a friend link.
    public var proposalID: UUID? {
        if case .proposal(let id, _) = self { return id }
        return nil
    }

    /// The plan title hint; nil for a friend link.
    public var title: String? {
        if case .proposal(_, let title) = self { return title }
        return nil
    }

    /// The friend link's token; nil for a plan link.
    public var friendToken: String? {
        if case .friend(let token, _) = self { return token }
        return nil
    }

    /// The name hint on a friend link; nil for a plan link.
    public var friendName: String? {
        if case .friend(_, let name) = self { return name }
        return nil
    }

    /// The custom-scheme form. Always available, and what a build with no website shares.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .proposal(let id, let title):
            components.host = Self.proposalHost
            components.path = "/\(id.uuidString.lowercased())"
            // Sanitized on the way out as well as in. A title that would be rejected on arrival has
            // no business being put into a link we hand someone.
            if let title = Self.sanitizedTitle(title) {
                components.queryItems = [URLQueryItem(name: Self.titleKey, value: title)]
            }
        case .friend(let token, let name):
            components.host = Self.friendHost
            components.path = "/\(token)"
            if let name = Self.sanitizedTitle(name, cap: Self.maxNameLength) {
                components.queryItems = [URLQueryItem(name: Self.nameKey, value: name)]
            }
        }
        // The components are built from a UUID or a validated token and a sanitized string, so this cannot fail.
        return components.url!
    }

    /// The https form, `friendcal.app/f/<token>` or `/p/<uuid>`.
    public var webURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.webHost
        switch self {
        case .proposal(let id, let title):
            components.path = "/\(Self.proposalWebPath)/\(id.uuidString.lowercased())"
            if let title = Self.sanitizedTitle(title) {
                components.queryItems = [URLQueryItem(name: Self.titleKey, value: title)]
            }
        case .friend(let token, let name):
            components.path = "/\(Self.friendWebPath)/\(token)"
            if let name = Self.sanitizedTitle(name, cap: Self.maxNameLength) {
                components.queryItems = [URLQueryItem(name: Self.nameKey, value: name)]
            }
        }
        return components.url!
    }

    /// What the app hands to the share sheet: https once the site ships, the custom scheme until then.
    public var shareURL: URL { Self.useWebLinks ? webURL : url }
}
