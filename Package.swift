// swift-tools-version:5.9
import PackageDescription

let package = Package(
	name: "Belve",
	platforms: [.macOS(.v14)],
	targets: [
		.executableTarget(
			name: "Belve",
			path: "Sources/Belve",
			resources: [
				.copy("Resources"),
			]
		),
		.testTarget(
			name: "BelveTests",
			dependencies: ["Belve"],
			path: "Tests/BelveTests"
		),
	]
)
