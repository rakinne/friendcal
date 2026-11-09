import Foundation

/// The city the host picked last, prefilled on New plan so a regular host does not search for the same
/// city every time (design 3.1A). One city per device, kept in UserDefaults as `name|latitude|longitude`.
///
/// A plain string on purpose: UI tests pin it with a launch argument, which overrides the persisted
/// value for reads, and `UserDefaults` silently drops an argument value that looks like JSON or a
/// property list (verified: `{"name":...}` reads back as nil). `-FriendCalLastCity none` is "no last
/// city" (unreadable, so nil); `-FriendCalLastCity 'Austin, TX|30.2672|-97.7431'` is a prefill.
public struct LastUsedCity {
    public static let key = "FriendCalLastCity"
    private static let separator: Character = "|"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Nil when nothing is saved, the text does not parse, or the city fails the SQL-mirroring
    /// `isValid` (a stale or hand-edited value must never reach Create).
    public func load() -> SearchArea? {
        guard let text = defaults.string(forKey: Self.key) else { return nil }
        // Latitude and longitude are the last two fields, so a name that contains the separator
        // still parses: everything before them is the name.
        let fields = text.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3,
              let latitude = Double(fields[fields.count - 2]),
              let longitude = Double(fields[fields.count - 1]) else { return nil }
        let name = fields.dropLast(2).joined(separator: String(Self.separator))
        let area = SearchArea(name: name, latitude: latitude, longitude: longitude)
        return area.isValid ? area : nil
    }

    /// Ignores a city that is not valid, so the stored value is always one `load` would return.
    public func save(_ area: SearchArea) {
        guard area.isValid else { return }
        defaults.set("\(area.name)\(Self.separator)\(area.latitude)\(Self.separator)\(area.longitude)", forKey: Self.key)
    }

    /// Forgets the saved city. Sign-out calls it: the value is per device, not per account, so the
    /// next account must not inherit the previous person's home city.
    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
