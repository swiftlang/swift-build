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

#if os(Windows)
import WinSDK
#elseif canImport(CryptoKit)
private import CryptoKit
#else
private import Crypto
#endif

public import Foundation

/// An HashContext object can be created to build up a set of input and generate a signature from it.
///
/// Such a context is a one-shot object: Once the signature has been retrieved from it, no more input content can be added to it.
public protocol HashContext: ~Copyable {
    /// Add the contents of `bytes` to the hash.
    func add<D: DataProtocol>(bytes: D)

    /// Finalize the hash (if not already finalized) and return the computed signature string.
    var signature: ByteString { mutating get }
}

extension HashContext {
    /// Add the contents of `string` to the hash.
    public func add(string: String) {
        add(bytes: Array(string.utf8))
    }

    /// Add the contents of `value` to the hash.
    public func add<T: FixedWidthInteger>(number value: T) {
        var local = value.littleEndian
        withUnsafeBytes(of: &local) { ptr in
            add(bytes: Array(ptr))
        }
    }
}

#if os(Windows)
fileprivate final class BCryptHashContext: HashContext {
    private let digestLength: Int
    private var hAlgorithm: BCRYPT_ALG_HANDLE?
    private var hash: BCRYPT_HASH_HANDLE?

    @usableFromInline
    internal var result: ByteString?

    public init(algorithm: String, digestLength: Int) {
        self.digestLength = digestLength
        algorithm.withCString(encodedAs: UTF16.self) { wName in
            precondition(BCryptOpenAlgorithmProvider(&hAlgorithm, wName, nil, 0) == 0)
        }
        precondition(BCryptCreateHash(hAlgorithm, &hash, nil, 0, nil, 0, 0) == 0)
    }

    deinit {
        precondition(BCryptDestroyHash(hash) == 0)
        precondition(BCryptCloseAlgorithmProvider(hAlgorithm, 0) == 0)
    }

    public func add<D: DataProtocol>(bytes: D) {
        precondition(result == nil, "tried to add additional context to a finalized HashContext")
        var byteArray = Array(bytes)
        byteArray.withUnsafeMutableBufferPointer { buffer in
            precondition(BCryptHashData(hash, buffer.baseAddress, numericCast(buffer.count), 0) == 0)
        }
    }

    public var signature: ByteString {
        guard let result = self.result else {
            let digest = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: digestLength) {
                precondition(BCryptFinishHash(hash, $0.baseAddress, numericCast($0.count), 0) == 0)
                return Array($0)
            }
            let byteCount = digestLength

            var result = [UInt8](repeating: 0, count: Int(byteCount) * 2)

            digest.withUnsafeBytes { ptr in
                for i in 0..<byteCount {
                    let value = ptr[i]
                    result[i*2 + 0] = hexchar(value >> 4)
                    result[i*2 + 1] = hexchar(value & 0x0F)
                }
            }

            let tmp = ByteString(result)
            self.result = tmp
            return tmp
        }
        return result
    }
}

@available(*, unavailable)
extension BCryptHashContext: Sendable { }
#else
fileprivate final class SwiftCryptoHashContext<HF: HashFunction>: HashContext {
    @usableFromInline
    internal var hash = HF()

    @usableFromInline
    internal var result: ByteString?

    public init() {
    }

    public func add<D: DataProtocol>(bytes: D) {
        precondition(result == nil, "tried to add additional context to a finalized HashContext")
        hash.update(data: bytes)
    }

    public var signature: ByteString {
        guard let result = self.result else {
            let digest = hash.finalize()
            let byteCount = type(of: digest).byteCount
            
            var result = [UInt8](repeating: 0, count: Int(byteCount) * 2)
            
            digest.withUnsafeBytes { ptr in
                for i in 0..<byteCount {
                    let value = ptr[i]
                    result[i*2 + 0] = hexchar(value >> 4)
                    result[i*2 + 1] = hexchar(value & 0x0F)
                }
            }
            
            let tmp = ByteString(result)
            self.result = tmp
            return tmp
        }
        return result
    }
}

@available(*, unavailable)
extension SwiftCryptoHashContext: Sendable { }
#endif

/// Convert a hexadecimal digit to a lowecase ASCII character value.
private func hexchar(_ value: UInt8) -> UInt8 {
    assert(value >= 0 && value < 16)
    if value < 10 {
        return UInt8(ascii: "0") + value
    } else {
        return UInt8(ascii: "a") + (value - 10)
    }
}

public class DelegatedHashContext: HashContext {
    private var impl: any HashContext

    fileprivate init(impl: consuming any HashContext) {
        self.impl = impl
    }

    public func add<D: DataProtocol>(bytes: D) {
        impl.add(bytes: bytes)
    }

    public var signature: ByteString {
        impl.signature
    }
}

public final class MD5Context: DelegatedHashContext {
    public init() {
        #if os(Windows)
        super.init(impl: BCryptHashContext(algorithm: "MD5", digestLength: 16))
        #else
        super.init(impl: SwiftCryptoHashContext<Insecure.MD5>())
        #endif
    }
}

@available(*, unavailable)
extension MD5Context: Sendable { }

public final class SHA256Context: DelegatedHashContext {
    public init() {
        #if os(Windows)
        super.init(impl: BCryptHashContext(algorithm: "SHA256", digestLength: 32))
        #else
        super.init(impl: SwiftCryptoHashContext<SHA256>())
        #endif
    }
}

@available(*, unavailable)
extension SHA256Context: Sendable { }
