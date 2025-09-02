//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import SWBTestSupport
import SwiftBuild
import SWBUtil
import Testing
import SwiftBuildTestSupport

@Suite(.skipHostOS(.windows))
fileprivate struct BuildCommandTests {
    private let commandSequenceCodec: any CommandSequenceEncodable = LLVMStyleCommandCodec()

    private func pif(basePath: Path = Path.root.join("tmp")) -> SWBPropertyListItem {
        let workspacePIF: SWBPropertyListItem = [
            "guid": "W1",
            "name": "aWorkspace",
            "path": .plString(basePath.join("aWorkspace.xcworkspace").join("contents.xcworkspacedata").str),
            "projects": ["P1"]
        ]
        let projectPIF: SWBPropertyListItem = [
            "guid": "P1",
            "path": .plString(basePath.join("aProject.xcodeproj").str),
            "targets": ["T1"],
            "groupTree": [
                "guid": "G1",
                "type": "group",
                "name": "SomeFiles",
                "sourceTree": "PROJECT_DIR",
                "path": .plString(basePath.join("SomeProject").join("SomeFiles").str)
            ],
            "buildConfigurations": [
                [
                    "guid": "BC1",
                    "name": "Config1",
                    "buildSettings": [
                        "USER_PROJECT_SETTING": "USER_PROJECT_VALUE"
                    ]
                ]
            ],
            "defaultConfigurationName": "Config1",
            "developmentRegion": "English"
        ]
        let targetPIF: SWBPropertyListItem = [
            "guid": "T1",
            "name": "aTarget",
            "type": "standard",
            "buildRules": [],
            "buildPhases": [],
            "buildConfigurations": [
                [
                    "guid": "TC1",
                    "name": "Config1",
                    "buildSettings": [
                        "USER_PROJECT_SETTING": "USER_PROJECT_VALUE"
                    ]
                ]
            ],
            "dependencies": [],
            "productTypeIdentifier": "com.apple.product-type.tool",
            "productReference": [
                "guid": "PR1",
                "name": "aTarget"
            ]
        ]
        let topLevelPIF: SWBPropertyListItem = [
            [
                "type": "workspace",
                "signature": "W1",
                "contents": workspacePIF
            ],
            [
                "type": "project",
                "signature": "P1",
                "contents": projectPIF
            ],
            [
                "type": "target",
                "signature": "T1",
                "contents": targetPIF
            ]
        ]
        return topLevelPIF
    }

    @Test(.skipHostOS(.windows)) // PTY not supported on Windows
    func buildCommandWithPIF() async throws {
        let supportedPIFFileExtensions = ["json", "pif"]
        for fileExtension in supportedPIFFileExtensions {
            try await withTemporaryDirectory { tmp in
                let pifPath = tmp.join("pif.\(fileExtension)")
                try pif(basePath: tmp).propertyListItem.asJSONFragment().unsafeStringValue.write(to: URL(fileURLWithPath: pifPath.str), atomically: true, encoding: .utf8)

                try await withCLIConnection { cli in
                    try cli.send(command: commandSequenceCodec.encode(["build", pifPath.str]))

                    let reply = try await cli.getResponse()
                    #expect(reply.contains(#"{"kind":"buildCompleted","result":"#), Comment(rawValue: reply))

                    try cli.send(command: "quit")
                    _ = try await cli.getResponse()

                    await #expect(try cli.exitStatus == .exit(0))
                }
            }
        }
    }

    @Test(.skipHostOS(.windows)) // PTY not supported on Windows
    func buildCommandWithPIFRelativePath() async throws {
        let supportedPIFFileExtensions = ["json", "pif"]
        for fileExtension in supportedPIFFileExtensions {
            try await withTemporaryDirectory { tmp in
                let pifPath = tmp.join("pif.\(fileExtension)")
                try pif(basePath: tmp).propertyListItem.asJSONFragment().unsafeStringValue.write(to: URL(fileURLWithPath: pifPath.str), atomically: true, encoding: .utf8)

                try await withTemporaryDirectory { toolDirectory in
                    let relativePifPath = "../../\(tmp.dirname.basename)/\(tmp.basename)/pif.\(fileExtension)"

                    try await withCLIConnection(currentDirectory: toolDirectory) { cli in
                        try cli.send(command: commandSequenceCodec.encode(["build", relativePifPath]))

                        let reply = try await cli.getResponse()
                        #expect(reply.contains(#"{"kind":"buildCompleted","result":"#), Comment(rawValue: reply))

                        try cli.send(command: "quit")
                        _ = try await cli.getResponse()

                        await #expect(try cli.exitStatus == .exit(0))
                    }
                }
            }
        }
    }

    @Test(.skipHostOS(.windows)) // PTY not supported on Windows
    func buildCommandWithPIFAndTargetOverride() async throws {
        let supportedPIFFileExtensions = ["json", "pif"]
        for fileExtension in supportedPIFFileExtensions {
            try await withTemporaryDirectory { tmp in
                let pifPath = tmp.join("pif.\(fileExtension)")
                try pif(basePath: tmp).propertyListItem.asJSONFragment().unsafeStringValue.write(to: URL(fileURLWithPath: pifPath.str), atomically: true, encoding: .utf8)

                try await withCLIConnection { cli in
                    try cli.send(command: commandSequenceCodec.encode(["build", pifPath.str, "--derivedDataPath", "\(tmp.str)/.buildData", "--target", "aTarget"]))

                    let reply = try await cli.getResponse()
                    #expect(reply.contains(#"{"kind":"buildCompleted","result":"#), Comment(rawValue: reply))

                    try cli.send(command: "quit")
                    _ = try await cli.getResponse()

                    await #expect(try cli.exitStatus == .exit(0))

                    // Make sure the arenaInfo was passed to the build parameters
                    // for the build request _and_ the build request's targets,
                    // otherwise the targets will fall back to the default SYMROOT
                    // of $PROJECT_DIR/build
                    #expect(!localFS.exists(tmp.join("build")),
                            "unexpectedly built into the default SYMROOT instead of the build arena")
                    #expect(localFS.exists(tmp.join(".buildData/Products/Config1\(SWBRunDestinationInfo.host.builtProductsDirSuffix)")),
                            "could not find configuration build directory in build arena")
                }
            }
        }
    }

    @Test(arguments: [true, false])
    func buildCommandWithUserDefaults(enableDebugActivityLogs: Bool) async throws {
        try await withTemporaryDirectory { tmp in
            let pifPath = tmp.join("pif.json")
            try pif(basePath: tmp).propertyListItem.asJSONFragment().unsafeStringValue.write(to: URL(fileURLWithPath: pifPath.str), atomically: true, encoding: .utf8)

            let swiftbuildPath = try CLIConnection.swiftbuildToolURL.filePath
            let reply = try await runProcess([swiftbuildPath.str, "build", "\(pifPath.str)", "--derivedDataPath", "\(tmp.str)/.buildData", "--target", "aTarget", "-EnableDebugActivityLogs", "\(enableDebugActivityLogs ? "YES" : "NO")"], environment: CLIConnection.environment)

            #expect(reply.contains(#"{"kind":"buildCompleted","result":"#), Comment(rawValue: reply))
            #expect(reply.contains(#"{"data":"Received inputs for target <ConfiguredTarget target: aTarget:T1>: ProvisioningTaskInputs"#) == enableDebugActivityLogs, Comment(rawValue: reply))
        }
    }

    @Test(.requireHostOS(.macOS)) // uses xcodebuild
    func buildCommandWithXcodeProject() async throws {
        let projectPath = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("TestData")
            .appendingPathComponent("CommandLineTool")
            .appendingPathComponent("CommandLineTool.xcodeproj").path

        try await withCLIConnection { cli in
            try cli.send(command: commandSequenceCodec.encode(["build", projectPath]))

            let reply = try await cli.getResponse()
            #expect(reply.contains(#"{"kind":"buildCompleted","result":"ok"}"#), Comment(rawValue: reply))

            try cli.send(command: "quit")
            _ = try await cli.getResponse()

            await #expect(try cli.exitStatus == .exit(0))
        }
    }

    @Test(.requireHostOS(.macOS)) // uses xcodebuild
    func buildCommandWithXcodeWorkspace() async throws {
        let workspacePath = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("TestData")
            .appendingPathComponent("CommandLineTool")
            .appendingPathComponent("CommandLineTool.xcworkspace").path

        try await withCLIConnection { cli in
            try cli.send(command: commandSequenceCodec.encode(["build", workspacePath]))

            let reply = try await cli.getResponse()
            #expect(reply.contains(#"{"kind":"buildCompleted","result":"ok"}"#), Comment(rawValue: reply))

            try cli.send(command: "quit")
            _ = try await cli.getResponse()

            await #expect(try cli.exitStatus == .exit(0))
        }
    }

    @Test(.requireHostOS(.macOS)) // uses xcodebuild
    func buildCommandWithSwiftPackage() async throws {
        let packagePath = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("TestData")
            .appendingPathComponent("CommandLineToolPackage").path

        try await withCLIConnection { cli in
            try cli.send(command: commandSequenceCodec.encode(["build", packagePath]))

            let reply = try await cli.getResponse()
            #expect(reply.contains(#"{"kind":"buildCompleted","result":"ok"}"#), Comment(rawValue: reply))

            try cli.send(command: "quit")
            _ = try await cli.getResponse()

            await #expect(try cli.exitStatus == .exit(0))
        }
    }
}
