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

public import Foundation
#if os(macOS)
private import Security
#endif

public struct CodeSignatureInfo: Codable, Sendable {
    public enum Error: Swift.Error {
        case notSupported
        case codesignVerificationFailed(description: String, output: String)
    }

    enum CodingKeys: String, CodingKey {
        case isSigned = "signed"
        case identifier = "bundleIndentifier" // NOTE: bundle identifier is mis-spelled
        case mainExecutable = "mainExecutable"
        case source = "source"
        case runtimeVersion = "runtimeVersion"
        case cdHashes = "cdhashes"
        case timestamp = "timestamp"
        case isSecureTimestamp = "isSecureTimestamp"
        case certificates = "certificates"
        case additionalInfo = "metadata"
        case signatureType = "signatureType"
        case signatureIdentifier = "signatureIdentifier"
    }

    // Attributes derived from SecCodeInfo* APIs.
    public let isSigned: Bool
    public let identifier: String?
    public let mainExecutable: String?
    public let source: String?
    public let runtimeVersion: String?
    public let cdHashes: [Data]?
    public let timestamp: String?
    public let isSecureTimestamp: Bool
    public let certificates: [Data]?

    // Custom attributes not returned by SecCodeInfo* APIs.
    public let signatureType: SignatureType?
    public let signatureIdentifier: String?
    public let additionalInfo: [String:String]?

    public enum SignatureType: String, Codable, Sendable {
        case appleDeveloperProgram = "AppleDeveloperProgram"
        case selfSigned = "SelfSigned"
    }

    #if os(macOS)
    init(_ dict: NSDictionary?, additionalInfo: [String:String]?) {
        self.additionalInfo = additionalInfo

        guard let dict else {
            self.isSigned = false
            self.identifier = nil
            self.mainExecutable = nil
            self.source = nil
            self.runtimeVersion = nil
            self.cdHashes = nil
            self.timestamp = nil
            self.isSecureTimestamp = false
            self.certificates = nil

            self.signatureType = nil
            self.signatureIdentifier = nil

            return
        }

        self.identifier = dict[kSecCodeInfoIdentifier] as? String

        // According to `SecCode.h`, this is the recommended way to determine if an item is signed.
        self.isSigned = identifier != nil

        if let certificates = dict[kSecCodeInfoCertificates] as? NSArray {
            self.certificates = certificates.compactMap { SecCertificateCopyData($0 as! SecCertificate) as Data }
        }
        else {
            self.certificates = nil
        }

        // NOTE: Other types of signatures will be supported at a later date: rdar://105992196.
        if let appleDeveloperTeamID = dict[kSecCodeInfoTeamIdentifier] as? String {
            self.signatureType  = SignatureType.appleDeveloperProgram
            self.signatureIdentifier = appleDeveloperTeamID
        }
        else if isSigned {
            // NOTE: "signed" binaries with no code certificates are currently treated as un-signed as there is no
            // real signature data to validate. This is a design choice instead of just relying on the identifier,
            // which could be changed by anyone.
            if let firstCert = self.certificates?.first {
                self.signatureType = SignatureType.selfSigned
                self.signatureIdentifier = firstCert.sha256HexString
            }
            else {
                self.signatureType = nil
                self.signatureIdentifier = nil
            }
        }
        else {
            self.signatureType = nil
            self.signatureIdentifier = nil
        }

        self.mainExecutable = dict[kSecCodeInfoMainExecutable] as? String
        self.source = dict[kSecCodeInfoSource] as? String
        self.runtimeVersion = dict[kSecCodeInfoRuntimeVersion] as? String
        if let hashes = dict[kSecCodeInfoCdHashes] as? NSArray {
            self.cdHashes = hashes.compactMap { $0 as? Data }
        }
        else {
            self.cdHashes = nil
        }

        if let secureTimestamp = dict[kSecCodeInfoTimestamp] as? String {
            self.timestamp = secureTimestamp
            self.isSecureTimestamp = true
        }
        else if let timestamp = dict[kSecCodeInfoTime] as? String {
            self.timestamp = timestamp
            self.isSecureTimestamp = false
        }
        else {
            self.timestamp = nil
            self.isSecureTimestamp = false
        }
    }
    #endif

    static public func invokeCodesignVerification(for path: String, treatUnsignedAsError: Bool) async throws {
        #if os(macOS)
        let executionResult = try await Process.getOutput(url: URL(filePath: "/usr/bin/codesign"), arguments: ["-vvvv", path])
        let stdoutContent = String(data: executionResult.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrContent = String(data: executionResult.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // codesign puts the `-vvvv` additional content into stdout, whereas the initial message is in stderr.
        let output = "\(stderrContent)\n\(stdoutContent)"

        guard executionResult.exitStatus.isSuccess else {
            if stderrContent.contains("code object is not signed at all") {
                if treatUnsignedAsError {
                    throw CodeSignatureInfo.Error.codesignVerificationFailed(description: "Code object is not signed", output: output)
                }
                else {
                    // this is fine
                    return
                }
            }
            else if stderrContent.contains("a sealed resource is missing or invalid") {
                throw CodeSignatureInfo.Error.codesignVerificationFailed(description: "A sealed resource is missing or invalid", output: output)
            }
            else if stderrContent.contains("CSSMERR_TP_CERT_REVOKED") {
                throw CodeSignatureInfo.Error.codesignVerificationFailed(description: "The signing certificate has been revoked (CSSMERR_TP_CERT_REVOKED)", output: output)
            }
            else {
                throw CodeSignatureInfo.Error.codesignVerificationFailed(description: "Codesign verification failed", output: output)
            }
        }
        #else
        // FIXME:When implementing rdar://107627846, we need to think about out to have this codepath use the ClientExecutionDelegates
        // in order to allow for different platform overrides on execution.
        #endif
    }

    static public func load(from path: Path, additionalInfo: [String:String]?, skipValidation: Bool = false) async throws -> CodeSignatureInfo {
        return try await Self.load(from: path.str, additionalInfo: additionalInfo, skipValidation: skipValidation)
    }

    static public func load(from path: String, additionalInfo: [String:String]?, skipValidation: Bool = false) async throws -> CodeSignatureInfo {
        #if os(macOS)
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()

        var info: CFDictionary?
        var code: SecStaticCode?

        let result = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &code)
        if result != 0 {
            throw MacError(result)
        }

        let result2 = SecCodeCopySigningInformation(code!, [SecCSFlags(rawValue: kSecCSSigningInformation)], &info)
        if result2 != 0 {
            throw MacError(result)
        }

        if !skipValidation {
            try await invokeCodesignVerification(for: path, treatUnsignedAsError: false)
        }

        return CodeSignatureInfo(info as NSDictionary?, additionalInfo: additionalInfo)
        #else
        throw Error.notSupported
        #endif
    }
}


public extension Data {
    var sha256HexString: String {
        let sha = SHA256Context()
        sha.add(bytes: ByteString(self))
        return sha.signature.asString.uppercased()
    }
}
