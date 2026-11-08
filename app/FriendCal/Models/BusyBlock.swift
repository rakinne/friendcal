import Foundation

public enum BusyVisibility: String, Codable, Sendable {
    case `public`
    case stealth // hiddenFrom contains excluded user IDs (e.g. Jalen)
}

public struct BusyBlock: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var userID: UUID
    public var range: DateRange
    public var visibility: BusyVisibility
    public var hiddenFrom: [UUID] // empty = public; non-empty = stealth — must be enforced server-side (RLS)
    /// The locked plan that promoted this block, when one did. Nil for a block someone made themselves.
    ///
    /// A correlation key: it joins two people's blocks to one plan, which is why `authenticated` has
    /// no SELECT on `busy_blocks.source_proposal_id` at all (supabase/rls.sql section 8). It is
    /// therefore nil on anything that came from a plain read, and populated only where the server
    /// authorized it — the rows `my_commitments()` returns, which arrive as `Commitment`, not as
    /// `BusyBlock`. Treat a non-nil value here as something you were given, never as something to
    /// fetch.
    public var sourceProposalID: UUID?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        userID: UUID,
        range: DateRange,
        visibility: BusyVisibility = .public,
        hiddenFrom: [UUID] = [],
        sourceProposalID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.range = range
        self.visibility = visibility
        self.hiddenFrom = hiddenFrom
        self.sourceProposalID = sourceProposalID
        self.createdAt = createdAt
    }

    // There is deliberately no `eventID` on this type. The server has one, and revokes it from every
    // client, because it is the key that joins two people's blocks into one identifiable event. Not
    // modelling it at all is the strongest available guarantee that no screen can read it.
}

/// The narrow form: everything any viewer is allowed to know about someone else's busy time.
///
/// Separate from `BusyBlock` on purpose. A screen handed one of these cannot leak a correlation
/// field because the field is not there to leak — the guarantee is structural rather than a rule
/// somebody has to remember.
public struct SanitizedBusy: Codable, Equatable, Sendable {
    public var id: UUID
    public var userID: UUID
    public var range: DateRange

    public init(id: UUID, userID: UUID, range: DateRange) {
        self.id = id
        self.userID = userID
        self.range = range
    }
    // No title, no location, no host avatar, no attendee list, no event id, no provenance.
    // Render as an identical grey "Busy" — the same component manual Busy uses.
}

extension BusyBlock {
    /// THE ONE NAMED BLANKING SITE.
    ///
    /// Before this existed, three places each hand-built their own "safe" block with its own
    /// explicit field list: `InMemoryProposalStore.fetchBusyBlocks`, `StealthService.sanitize` and
    /// `SupabaseService`'s row decode. Three lists that must all stay correct forever is the
    /// hand-synced-list failure mode, and the moment a field is added to `BusyBlock` they disagree:
    /// whichever site returns `block` unchanged for an included viewer starts carrying the new field,
    /// and no test fails. Every one of those sites now routes through here.
    ///
    /// What it does: an excluded viewer gets a block indistinguishable from an ordinary one — same
    /// id, same person, same time, `visibility` normalised to `.public` and `hiddenFrom` emptied, so
    /// nothing about the row says "this one was hidden from you". Provenance is dropped for EVERY
    /// viewer, excluded or not, because no client may read it: it arrives through `my_commitments()`
    /// or not at all.
    ///
    /// Note it does not remove the row. An absent block is itself the tell — the excluded viewer must
    /// see that the time is taken, and learn nothing else.
    ///
    /// NO VIEWER PARAMETER, and that is the point. The task this implements was specified as
    /// `sanitized(for:)`, and taking a viewer would have meant blanking conditionally — full fields
    /// for an included viewer, stripped fields for an excluded one. But a shape that differs by
    /// viewer IS the correlation signal the whole design exists to remove: "the field is present, so
    /// I am not the one being hidden from" is exactly the inference an excluded viewer must not be
    /// able to draw. It also matches the server, which revokes all three correlation columns from
    /// every client, host included, not just from the excluded. One shape for everybody, so there is
    /// nothing to compare. A parameter here would also have been unused, which invites the next
    /// reader to assume it is doing something.
    public var sanitized: BusyBlock {
        BusyBlock(
            id: id,
            userID: userID,
            range: range,
            visibility: .public,
            hiddenFrom: [],
            sourceProposalID: nil,
            createdAt: createdAt
        )
    }

    /// The same blanking, reduced to the narrow type.
    public var sanitizedBusy: SanitizedBusy {
        SanitizedBusy(id: id, userID: userID, range: range)
    }
}

struct Event: Identifiable, Codable {
    var id: UUID
    var title: String
    var date: Date
    var venue: String?
    var hostID: UUID
    var attendeeIDs: [UUID]
    var busyBlockIDs: [UUID] // backing holds (stealth-aware)
    var potluckItems: [String] = []
    var playlistURL: URL?
    // Hype art template reference — Partiful-inspired
    var inviteArtTemplate: String = "partiful-classic"
}
