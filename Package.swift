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
			dependencies: ["SwiftTerm"],
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
