// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "Belve",
	platforms: [.macOS(.v14)],
	dependencies: [
	],
	targets: [
		.executableTarget(
			name: "Belve",
			path: "Sources/Belve",
			resources: [
				.copy("Resources"),
			],
			linkerSettings: [
				.linkedFramework("WebKit"),
				.linkedFramework("QuartzCore"),
				.linkedFramework("CoreText"),
			]
		),
		.testTarget(
			name: "BelveTests",
			dependencies: ["Belve"],
			path: "Tests/BelveTests"
		),
	]
)
