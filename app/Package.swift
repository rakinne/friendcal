// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "FriendCal",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FriendCalCore", targets: ["FriendCalCore"])],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.5.0"),
    ],
    targets: [
        .target(name: "FriendCalCore", dependencies: [.product(name: "Supabase", package: "supabase-swift")], path: "FriendCal", exclude: ["FriendCalApp.swift", "Views", "Secrets.plist", "Secrets.plist.template"], sources: ["Models", "Services", "Privacy", "Shared"]),
        .testTarget(name: "FriendCalTests", dependencies: ["FriendCalCore"], path: "FriendCalTests"),
    ]
)
