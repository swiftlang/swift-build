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

public import SWBCore
import SWBLibc
import SWBUtil
import Foundation

/// Performs the processing of a given XCFramework, doing the work to process an individual slice and outputting into a location that can be used during the build.
public final class ProcessXCFrameworkTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "process-xcframework"
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {

        let generator = task.commandLineAsStrings.makeIterator()
        _ = generator.next() // consume program name

        var xcframeworkPath: Path?
        var platform: String?
        var environment: String?
        var targetPath: Path?
        var expectedSignatures: [String] = []
        var skipSignatureValidation: Bool = false

        while let arg = generator.next() {
            switch arg {
            case "--xcframework":
                guard let value = generator.next() else {
                    outputDelegate.emitError("`--xcframework` requires a parameter")
                    return .failed
                }
                xcframeworkPath = Path(value)

            case "--platform":
                guard let value = generator.next() else {
                    outputDelegate.emitError("`--platform` requires a parameter")
                    return .failed
                }
                platform = value

            case "--environment":
                guard let value = generator.next() else {
                    outputDelegate.emitError("`--environment` requires a parameter")
                    return .failed
                }
                environment = value

            case "--target-path":
                guard let value = generator.next() else {
                    outputDelegate.emitError("`--target-path` requires a parameter")
                    return .failed
                }
                targetPath = Path(value)

            case "--expected-signature":
                guard let value = generator.next() else {
                    outputDelegate.emitError("`--expected-signature` requires a parameter")
                    return .failed
                }
                expectedSignatures.append(value)

            case "--skip-signature-validation":
                skipSignatureValidation = true

            default:
                outputDelegate.emitError("unexpected arguments '\(arg)'")
                return .failed
            }
        }

        guard let path = xcframeworkPath else {
            outputDelegate.emitError("--xcframework is a required argument")
            return .failed
        }

        guard let plat = platform else {
            outputDelegate.emitError("--platform is a required argument")
            return .failed
        }

        guard let target = targetPath else {
            outputDelegate.emitError("--target-path is a required argument")
            return .failed
        }

        do {
            let fs = executionDelegate.fs
            let xcframeworkName = path.basename
            let xcframework = try XCFramework(path: path, fs: fs)

            let platformDisplayName = BuildVersion.Platform(platform: plat, environment: environment)?.displayName(infoLookup: executionDelegate.infoLookup) ?? ("\(plat)" + (environment.flatMap { "-\($0)" } ?? ""))

            // Find a library in the XCFramework which is compatible with the current platform.
            // Note that we don't validate supported architectures here because this task copies the xcframework's contents for potential use by multiple targets which may have different architecture settings.
            guard let library = xcframework.findLibrary(platform: plat, platformVariant: environment ?? "") else {
                outputDelegate.emitError("While building for \(platformDisplayName), no library for this platform was found in '\(xcframeworkName)'.")
                return .failed
            }

            // Provide a friendly message up-front if the given library is not found within the XCFramework. This can occur when the Info.plist for an XCFramework points to a supported platform, but the corresponding library entry is incorrect or points to a location that does not exist on disk.
            let rootPathToLibrary = path.join(library.libraryIdentifier)
            let copyLibraryFromPath = rootPathToLibrary.join(library.libraryPath)
            if !fs.exists(copyLibraryFromPath) {
                outputDelegate.emitError("When building for \(platformDisplayName), the expected library \(copyLibraryFromPath.str) was not found in \(path.str)")
                return .failed
            }

            if skipSignatureValidation {
                // NOTE: Always emit the warning when enabled as this can cause issues in other environments, such as CI.
                outputDelegate.emitWarning("XCFramework signature validation is being skipped. Remove `DISABLE_XCFRAMEWORK_SIGNATURE_VALIDATION` to disable this warning.")
            }
            else if await !validateExpectedSignature(path, expectedSignatures: expectedSignatures, outputDelegate: outputDelegate) {
                return .failed
            }

            try xcframework.copy(library: library, from: path, to: target, fs: fs)
            return .succeeded
        }
        catch {
            outputDelegate.emitError(error.localizedDescription)
            return .failed
        }
    }

    func validateExpectedSignature(_ path: Path, expectedSignatures: [String], outputDelegate: any TaskOutputDelegate) async -> Bool {
        let location = Diagnostic.Location.path(path)

        do {
            // Codesign verification is always run, regardless of the expected signatures. If this fails, then builds should not be able to continue.
            try await CodeSignatureInfo.invokeCodesignVerification(for: path.str, treatUnsignedAsError: false)

            // No validation is performed if there are no expected signatures.
            if expectedSignatures.isEmpty {
                // If the asset is signed, and there are no expectations in the project, we issue a note, which is used to record the signing identity.
                let info = try? await CodeSignatureInfo.load(from: path.str, additionalInfo: nil)
                if let info, info.signatureType != nil, info.signatureIdentifier != nil {
                    let diagnostic = Diagnostic(behavior: .note, location: location, data: DiagnosticData("The identity of “\(path.basename)” is not recorded in your project."))
                    outputDelegate.emit(diagnostic)
                }
                return true
            }

            let info = try await CodeSignatureInfo.load(from: path.str, additionalInfo: nil)
            let signatures = expectedSignatures.compactMap({ ExpectedSignature($0) })

            guard !signatures.isEmpty else {
                // NOTE: This is likely an internal tooling error or adoption bring-up issue, so soft-error here.
                let diagnostic = Diagnostic(behavior: .error, location: location, data: DiagnosticData("Expected signatures are malformed"), childDiagnostics: [
                    Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Expected signatures: \(expectedSignatures.joined(separator: ","))")),
                    Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Replace or remove the expected signature data.")),
                ])
                outputDelegate.emit(diagnostic)
                return false
            }

            let childDiagnostics: [Diagnostic] = signatures.map({ Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData($0.diagnosticMessage)) })

            guard let signatureType = info.signatureType, let signatureIdentifier = info.signatureIdentifier else {
                let message = "“\(path.basename)” is not signed with the expected identity and may have been compromised."
                let diagnostic = Diagnostic(behavior: .error, location: location, data: DiagnosticData(message), childDiagnostics: childDiagnostics)
                outputDelegate.emit(diagnostic)
                return false
            }

            for signature in signatures {
                if signature.signatureType == signatureType && signature.identifier == signatureIdentifier {
                    // A match has been found, so return true and stop validating potential signatures.
                    return true
                }
            }

            let message = "“\(path.basename)” is not signed with the expected identity and may have been compromised."
            let diagnostic = Diagnostic(behavior: .error, location: location, data: DiagnosticData(message), childDiagnostics: childDiagnostics)

            outputDelegate.emit(diagnostic)
            return false
        }
        catch let CodeSignatureInfo.Error.codesignVerificationFailed(description, output) {
            let childDiagnostics = [
                Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData(description)),
                Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData(output)),
            ]
            let message = "The signature of “\(path.basename)” cannot be verified."
            let diagnostic = Diagnostic(behavior: .error, location: location, data: DiagnosticData(message), childDiagnostics: childDiagnostics)

            outputDelegate.emit(diagnostic)
            return false
        }
        catch {
            let childDiagnostics = [Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Unable to load signature information for '\(path.str)'. error=\(error.localizedDescription)"))]
            let message = "The signature of “\(path.basename)” cannot be validated and may have been compromised."
            let diagnostic = Diagnostic(behavior: .error, location: location, data: DiagnosticData(message), childDiagnostics: childDiagnostics)

            outputDelegate.emit(diagnostic)
            return false
        }
    }

    fileprivate struct ExpectedSignature {
        // The Xcode serialization of this signature content takes the form: <signature type>:<identifier>:<name>
        // The name is an optional field and Swift Build ignores it for any verification purposes.

        let signatureType: CodeSignatureInfo.SignatureType
        let identifier: String

        fileprivate init?(_ s: String) {
            let parts = s.split(separator: ":", maxSplits: 3).map { String($0) }

            guard let s = parts.first else { return nil }
            guard let type =  CodeSignatureInfo.SignatureType(rawValue: s) else { return nil }
            signatureType = type

            guard parts.count >= 2 else { return nil }
            identifier = parts[1]
        }

        var diagnosticMessage: String {
            switch signatureType {
            case .appleDeveloperProgram:
                return "Expected team identifier: \(identifier)"

            case .selfSigned:
                return "Expected fingerprint: \(identifier)"
            }
        }
    }
}
