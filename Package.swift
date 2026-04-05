// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "Belve",
	platforms: [.macOS(.v14)],
	dependencies: [
		.package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.11.1"),
	],
	targets: [
		.executableTarget(
			name: "Belve",
			dependencies: [
				"SwiftTerm",
				"GhosttyKit",
			],
			path: "Sources/Belve",
			resources: [
				.copy("Resources"),
			],
			linkerSettings: [
				.linkedFramework("Metal"),
				.linkedFramework("MetalKit"),
				.linkedFramework("QuartzCore"),
				.linkedFramework("IOSurface"),
				.linkedFramework("CoreText"),
				.linkedLibrary("z"),
				.linkedLibrary("c++"),
			]
		),
		.binaryTarget(
			name: "GhosttyKit",
			path: "GhosttyKit.xcframework"
		),
		.testTarget(
			name: "BelveTests",
			dependencies: ["Belve"],
			path: "Tests/BelveTests"
		),
	]
)
