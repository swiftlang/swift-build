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
#elseif canImport(CryptoKit)
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

fileprivate final class VendoredSHA256HashContext: HashContext {
    /// The length of the output digest (in bits).
    private static let digestLength = 256

    /// The size of each blocks (in bits).
    private static let blockBitSize = 512

    /// The initial hash value.
    private static let initalHashValue: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]

    /// The constants in the algorithm (K).
    private static let konstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    private var bytes: OutputByteStream

    init() {
        self.bytes = .init()
    }

    func add<D>(bytes: D) where D : DataProtocol {
        self.bytes.write(bytes)
    }

    var signature: ByteString {
        let digest =  self.hash(self.bytes.bytes)
        var result = [UInt8](repeating: 0, count: Int(digest.count) * 2)

        digest.bytes.withUnsafeBufferPointer { ptr in
            for i in 0..<ptr.count {
                let value = ptr[i]
                result[i*2 + 0] = hexchar(value >> 4)
                result[i*2 + 1] = hexchar(value & 0x0F)
            }
        }

        return ByteString(result)
    }

    private func hash(_ bytes: ByteString) -> ByteString {
        var input = bytes.bytes

        // Pad the input.
        pad(&input)

        // Break the input into N 512-bit blocks.
        let messageBlocks = input.blocks(size: Self.blockBitSize / 8)

        /// The hash that is being computed.
        var hash = Self.initalHashValue

        // Process each block.
        for block in messageBlocks {
            process(block, hash: &hash)
        }

        // Finally, compute the result.
        var result = [UInt8](repeating: 0, count: Self.digestLength / 8)
        for (idx, element) in hash.enumerated() {
            let pos = idx * 4
            result[pos + 0] = UInt8((element >> 24) & 0xff)
            result[pos + 1] = UInt8((element >> 16) & 0xff)
            result[pos + 2] = UInt8((element >> 8) & 0xff)
            result[pos + 3] = UInt8(element & 0xff)
        }

        return ByteString(result)
    }

    /// Process and compute hash from a block.
    private func process(_ block: ArraySlice<UInt8>, hash: inout [UInt32]) {

        // Compute message schedule.
        var W = [UInt32](repeating: 0, count: Self.konstants.count)
        for t in 0..<W.count {
            switch t {
            case 0...15:
                let index = block.startIndex.advanced(by: t * 4)
                // Put 4 bytes in each message.
                W[t]  = UInt32(block[index + 0]) << 24
                W[t] |= UInt32(block[index + 1]) << 16
                W[t] |= UInt32(block[index + 2]) << 8
                W[t] |= UInt32(block[index + 3])
            default:
                let σ1 = W[t-2].rotateRight(by: 17) ^ W[t-2].rotateRight(by: 19) ^ (W[t-2] >> 10)
                let σ0 = W[t-15].rotateRight(by: 7) ^ W[t-15].rotateRight(by: 18) ^ (W[t-15] >> 3)
                W[t] = σ1 &+ W[t-7] &+ σ0 &+ W[t-16]
            }
        }

        var a = hash[0]
        var b = hash[1]
        var c = hash[2]
        var d = hash[3]
        var e = hash[4]
        var f = hash[5]
        var g = hash[6]
        var h = hash[7]

        // Run the main algorithm.
        for t in 0..<Self.konstants.count {
            let Σ1 = e.rotateRight(by: 6) ^ e.rotateRight(by: 11) ^ e.rotateRight(by: 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ Σ1 &+ ch &+ Self.konstants[t] &+ W[t]

            let Σ0 = a.rotateRight(by: 2) ^ a.rotateRight(by: 13) ^ a.rotateRight(by: 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = Σ0 &+ maj

            h = g
            g = f
            f = e
            e = d &+ t1
            d = c
            c = b
            b = a
            a = t1 &+ t2
        }

        hash[0] = a &+ hash[0]
        hash[1] = b &+ hash[1]
        hash[2] = c &+ hash[2]
        hash[3] = d &+ hash[3]
        hash[4] = e &+ hash[4]
        hash[5] = f &+ hash[5]
        hash[6] = g &+ hash[6]
        hash[7] = h &+ hash[7]
    }

    /// Pad the given byte array to be a multiple of 512 bits.
    private func pad(_ input: inout [UInt8]) {
        // Find the bit count of input.
        let inputBitLength = input.count * 8

        // Append the bit 1 at end of input.
        input.append(0x80)

        // Find the number of bits we need to append.
        //
        // inputBitLength + 1 + bitsToAppend ≡ 448 mod 512
        let mod = inputBitLength % 512
        let bitsToAppend = mod < 448 ? 448 - 1 - mod : 512 + 448 - mod - 1

        // We already appended first 7 bits with 0x80 above.
        input += [UInt8](repeating: 0, count: (bitsToAppend - 7) / 8)

        // We need to append 64 bits of input length.
        for byte in UInt64(inputBitLength).toByteArray().lazy.reversed() {
            input.append(byte)
        }
        assert((input.count * 8) % 512 == 0, "Expected padded length to be 512.")
    }
}

private extension UInt64 {
    /// Converts the 64 bit integer into an array of single byte integers.
    func toByteArray() -> [UInt8] {
        var value = self.littleEndian
        return withUnsafeBytes(of: &value, Array.init)
    }
}

private extension UInt32 {
    /// Rotates self by given amount.
    func rotateRight(by amount: UInt32) -> UInt32 {
        return (self >> amount) | (self << (32 - amount))
    }
}

private extension Array {
    /// Breaks the array into the given size.
    func blocks(size: Int) -> AnyIterator<ArraySlice<Element>> {
        var currentIndex = startIndex
        return AnyIterator {
            if let nextIndex = self.index(currentIndex, offsetBy: size, limitedBy: self.endIndex) {
                defer { currentIndex = nextIndex }
                return self[currentIndex..<nextIndex]
            }
            return nil
        }
    }
}

/// Convert a hexadecimal digit to a lowercase ASCII character value.
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

public final class InsecureHashContext: DelegatedHashContext {
    public init() {
        #if os(Windows)
        super.init(impl: BCryptHashContext(algorithm: "MD5", digestLength: 16))
        #elseif canImport(CryptoKit)
        super.init(impl: SwiftCryptoHashContext<Insecure.MD5>())
        #else
        super.init(impl: VendoredSHA256HashContext())
        #endif
    }
}

@available(*, unavailable)
extension InsecureHashContext: Sendable { }

public final class SHA256Context: DelegatedHashContext {
    public init() {
        #if os(Windows)
        super.init(impl: BCryptHashContext(algorithm: "SHA256", digestLength: 32))
        #elseif canImport(CryptoKit)
        super.init(impl: SwiftCryptoHashContext<SHA256>())
        #else
        super.init(impl: VendoredSHA256HashContext())
        #endif
    }
}

@available(*, unavailable)
extension SHA256Context: Sendable { }
