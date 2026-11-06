import XCTest
@testable import FriendCalCore

final class FaceColorTests: XCTestCase {
    /// protects=a friend's face keeps its color across launches and devices; fails_when=the index
    /// comes from a per-process seeded hash or the FNV constants/modulus change; no_claim=the
    /// palette's hex values or contrast (DT5).
    func testPaletteIndexIsStableFNV1a() {
        XCTAssertEqual(DesignTokens.FacePalette.index(for: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), 4)
        XCTAssertEqual(DesignTokens.FacePalette.index(for: UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!), 3)
    }
}
