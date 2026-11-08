import Foundation

/// `friendcal://proposal/<uuid>?t=<title>` (issue #5 D3). `scheme` is the single Swift constant; a
/// unit test asserts CFBundleURLTypes in the app bundle matches it (red flag 8: no hand-synced list).
/// Universal links and a not-installed fallback are a TODO (D16).
public enum DeepLink: Equatable {
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

    public static let scheme = "friendcal"
    public static let proposalHost = "proposal"
    /// Query item carrying the title hint. Short because it goes in a message people see.
    public static let titleKey = "t"

    /// The longest title hint accepted. Anything longer is a payload, not a plan name, and would
    /// either blow up the invite layout or push the real content off screen.
    public static let maxTitleLength = 80

    /// nil for another scheme, another host, a missing or malformed id, or extra path components.
    ///
    /// Read through `URLComponents` rather than by splitting the string: percent-encoding,
    /// `+`-for-space and repeated query keys all have rules, and hand-parsing them is how a title
    /// like "Dad's 60th" arrives as "Dad%27s 60th" or how a second `?t=` silently wins.
    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == proposalHost else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let id = UUID(uuidString: parts[0]) else { return nil }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // First occurrence wins, deliberately and explicitly: a URL with two `t=` items is
        // malformed, and picking the first is at least stable rather than depending on parse order.
        let raw = components?.queryItems?.first { $0.name == titleKey }?.value
        return .proposal(id, title: sanitizedTitle(raw))
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
    public static func sanitizedTitle(_ raw: String?) -> String? {
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
        return String(text.prefix(maxTitleLength))
    }

    public var proposalID: UUID {
        switch self {
        case .proposal(let id, _): return id
        }
    }

    public var title: String? {
        switch self {
        case .proposal(_, let title): return title
        }
    }

    public var url: URL {
        switch self {
        case .proposal(let id, let title):
            var components = URLComponents()
            components.scheme = Self.scheme
            components.host = Self.proposalHost
            components.path = "/\(id.uuidString.lowercased())"
            // Sanitized on the way out as well as in. A title that would be rejected on arrival has
            // no business being put into a link we hand someone.
            if let title = Self.sanitizedTitle(title) {
                components.queryItems = [URLQueryItem(name: Self.titleKey, value: title)]
            }
            // The components are all built from a UUID and a sanitized string, so this cannot fail.
            return components.url!
        }
    }
}
