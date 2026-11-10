import Foundation

/// What a friend says they are doing (Groups, variant D). A status is something a person sets on
/// purpose; it is never derived from a calendar block, a hold or a hidden plan. That is the privacy
/// line: unlabeled time and every Stealth plan still reads as the plain grey "busy" (X1).
public enum StatusKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case work, movies, concert, gym, cooking, flying, studying, napping, free

    public var id: String { rawValue }

    /// The word shown next to the glyph. Shape plus word, never hue alone (D25).
    public var word: String {
        switch self {
        case .work: "work"
        case .movies: "movies"
        case .concert: "concert"
        case .gym: "gym"
        case .cooking: "cooking"
        case .flying: "flying"
        case .studying: "studying"
        case .napping: "napping"
        case .free: "free"
        }
    }

    /// A distinct silhouette per kind, so the states tell apart without color.
    public var symbolName: String {
        switch self {
        case .work: "person.text.rectangle.fill"
        case .movies: "ticket.fill"
        case .concert: "music.mic"
        case .gym: "dumbbell.fill"
        case .cooking: "fork.knife"
        case .flying: "airplane"
        case .studying: "book.fill"
        case .napping: "moon.zzz.fill"
        case .free: "sun.max.fill"
        }
    }

    /// Grey for "busy" and the quiet state, which are not kinds a person picks.
    public static let busySymbolName = "minus"

    /// An example away message, shown as the field's placeholder in the status sheet.
    public var messageExample: String {
        switch self {
        case .work: "closing shift, send snacks"
        case .movies: "no spoilers please"
        case .concert: "row 4, someone hold my coat"
        case .gym: "leg day, do not call"
        case .cooking: "something is on the stove"
        case .flying: "landing around nine"
        case .studying: "library, floor three"
        case .napping: "wake me for dinner"
        case .free: "down for tacos, anyone"
        }
    }

    /// "Leo's movie lets out in 1 h 30." The noun a Moments line hangs its ending on.
    var endNoun: String {
        switch self {
        case .work: "shift"
        case .movies: "movie"
        case .concert: "show"
        case .gym: "workout"
        case .cooking: "cooking"
        case .flying: "flight"
        case .studying: "study session"
        case .napping: "nap"
        case .free: "free time"
        }
    }

    /// "Nina has been at the concert for 40 min." What someone has been doing.
    var stayPhrase: String {
        switch self {
        case .work: "at work"
        case .movies: "at the movies"
        case .concert: "at the concert"
        case .gym: "at the gym"
        case .cooking: "cooking"
        case .flying: "in the air"
        case .studying: "studying"
        case .napping: "napping"
        case .free: "free"
        }
    }
}
