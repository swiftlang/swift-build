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
//
// MessagePack encoder and decoder.
//
// MessagePack specification is located at http://msgpack.org/
//
// IMPORTANT!!
//
// There have been hand-optimizations done here, so do not just blindly copy
// over this file with a different implementation!
//
//===----------------------------------------------------------------------===//


// MARK: MessagePack Encoder


/// An encoder for MessagePack.
///
/// This encoder provides a StAX-like interface.
public final class MsgPackEncoder: Encoder {
  // FIXME: This should be a Sink.
  // Currently it is not for performance reasons (StdlibUnittest
  // code can not be specialized).
  var bytes: [UInt8] = []

  // IMPORTANT!! This is done as a performance optimization.
  #if DEBUG
  internal let enableIntegrityChecks = true
  #else
  internal let enableIntegrityChecks = false
  #endif

  internal var _expectedElementCount: [Int] = [ 0 ]
  internal var _actualElementCount: [Int] = [ 0 ]

  internal func _appendBigEndian(_ value: Swift.UInt64) {
    var x = value.byteSwapped
    for _ in 0..<8 {
      bytes.append(UInt8(truncatingIfNeeded: x))
      x >>= 8
    }
  }

  internal func _appendBigEndian(_ value: Swift.UInt32) {
    var x = value.byteSwapped
    for _ in 0..<4 {
      bytes.append(UInt8(truncatingIfNeeded: x))
      x >>= 8
    }
  }

  internal func _appendBigEndian(_ value: Swift.UInt16) {
    var x = value.byteSwapped
    for _ in 0..<2 {
      bytes.append(UInt8(truncatingIfNeeded: x))
      x >>= 8
    }
  }

  internal func _appendBigEndian(_ value: Swift.Int64) {
    _appendBigEndian(Swift.UInt64(bitPattern: value))
  }

  internal func _addedElement() {
    if enableIntegrityChecks {
        _actualElementCount[_actualElementCount.count - 1] += 1
    }
  }

  public func append(_ i: Int64) {
    bytes.reserveCapacity(bytes.count + 9)
    bytes.append(0xd3)
    _appendBigEndian(i)

    _addedElement()
  }

  public func append(_ i: UInt64) {
    bytes.reserveCapacity(bytes.count + 9)
    bytes.append(0xcf)
    _appendBigEndian(i)

    _addedElement()
  }

  public func append(_ i: UInt8) {
    bytes.reserveCapacity(bytes.count + 2)
    bytes.append(0xe0)
    bytes.append(i)

    _addedElement()
  }

  public func appendNil() {
    bytes.append(0xc0)
    _addedElement()
  }

  public func append(_ b: Bool) {
    bytes.append(b ? 0xc3 : 0xc2)
    _addedElement()
  }

  public func append(_ f: Float32) {
    bytes.reserveCapacity(bytes.count + 5)
    bytes.append(0xca)
    _appendBigEndian(f.bitPattern)
    _addedElement()
  }

  public func append(_ f: Float64) {
    bytes.reserveCapacity(bytes.count + 9)
    bytes.append(0xcb)
    _appendBigEndian(f.bitPattern)
    _addedElement()
  }

  public func append(_ s: String) {
    let count = s.utf8.count
    switch Int64(count) {
    case 0...31:
      // fixstr
      bytes.append(0b1010_0000 | UInt8(count))
    case 32...0xff:
      // str8
      bytes.append(0xd9)
      bytes.append(UInt8(count))
    case 0x100...0xffff:
      // str16
      bytes.append(0xda)
      _appendBigEndian(UInt16(count))
    case 0x1_0000...0xffff_ffff:
      // str32
      bytes.append(0xdb)
      _appendBigEndian(UInt32(count))
    default:
      // FIXME: better error handling.  Trapping is at least secure.
      fatalError("string is too long")
    }

    bytes += s.utf8

    _addedElement()
  }

  public func append(_ dataBytes: [UInt8]) {
    switch Int64(dataBytes.count) {
    case 0...0xff:
      // bin8
      bytes.append(0xc4)
      bytes.append(UInt8(dataBytes.count))
    case 0x100...0xffff:
      // bin16
      bytes.append(0xc5)
      _appendBigEndian(UInt16(dataBytes.count))
    case 0x1_0000...0xffff_ffff:
      // bin32
      bytes.append(0xc6)
      _appendBigEndian(UInt32(dataBytes.count))
    default:
      // FIXME: better error handling.  Trapping is at least secure.
      fatalError("binary data is too long")
    }
    bytes += dataBytes

    _addedElement()
  }

  public func beginArray(_ count: Int) {
    switch Int64(count) {
    case 0...0xf:
      // fixarray
      bytes.append(0b1001_0000 | UInt8(count))
    case 0x10...0xffff:
      // array16
      bytes.append(0xdc)
      _appendBigEndian(UInt16(count))
    case 0x1_0000...0xffff_ffff:
      // array32
      bytes.append(0xdd)
      _appendBigEndian(UInt32(count))
    default:
      // FIXME: better error handling.  Trapping is at least secure.
      fatalError("array is too long")
    }

    if enableIntegrityChecks {
        _expectedElementCount.append(count)
        _actualElementCount.append(0)
    }
  }

  public func endArray() {
    if enableIntegrityChecks {
        let expectedCount = _expectedElementCount.removeLast()
        let actualCount = _actualElementCount.removeLast()
        if expectedCount != actualCount {
          fatalError("Actual number of elements in the array (\(actualCount)) does not match the expected number (\(expectedCount))")
        }

        _addedElement()
    }
  }

  public func append<T>(_ array: [T], encode: (T) -> Void) {
    self.beginArray(array.count)
    // NOTE: We explicit iterate over the count here as a micro-optimization: <rdar://problem/28665970> Manually iterating over count 10% faster than using iterator for generic array
    for i in 0 ..< array.count {
        encode(array[i])
    }
    self.endArray()
  }

  fileprivate func beginMap(_ mappingCount: Int) {
    switch Int64(mappingCount) {
    case 0...0xf:
      bytes.append(0b1000_0000 | UInt8(mappingCount))
    case 0x10...0xffff:
      bytes.append(0xde)
      _appendBigEndian(UInt16(mappingCount))
    case 0x1_0000...0xffff_ffff:
      bytes.append(0xdf)
      _appendBigEndian(UInt32(mappingCount))
    default:
      // FIXME: better error handling.  Trapping is at least secure.
      fatalError("map is too long")
    }

    if enableIntegrityChecks {
        _expectedElementCount.append(mappingCount * 2)
        _actualElementCount.append(0)
    }
  }

  fileprivate func endMap() {
    if enableIntegrityChecks {
        let expectedCount = _expectedElementCount.removeLast()
        let actualCount = _actualElementCount.removeLast()
        if expectedCount != actualCount {
          fatalError("Actual number of elements in the map (\(actualCount)) does not match the expected number (\(expectedCount))")
        }

        _addedElement()
    }
  }

  public func append<Tk: Comparable, Tv>(_ dict: [Tk: Tv], encodeKey: (Tk) -> Void, encodeValue: (Tv) -> Void) {
    self.beginMap(dict.count)
    for (key, value) in dict.sorted(byKey: <) {
      encodeKey(key)
      encodeValue(value)
    }
    self.endMap()
  }

  public func appendExtended(type: Int8, data: [UInt8]) {
    switch Int64(data.count) {
    case 1:
      // fixext1
      bytes.append(0xd4)
    case 2:
      // fixext2
      bytes.append(0xd5)
    case 4:
      // fixext4
      bytes.append(0xd6)
    case 8:
      // fixext8
      bytes.append(0xd7)
    case 16:
      // fixext16
      bytes.append(0xd8)
    case 0...0xff:
      // ext8
      bytes.append(0xc7)
      bytes.append(UInt8(data.count))
    case 0x100...0xffff:
      // ext16
      bytes.append(0xc8)
      _appendBigEndian(UInt16(data.count))
    case 0x1_0000...0xffff_ffff:
      // ext32
      bytes.append(0xc9)
      _appendBigEndian(UInt32(data.count))
    default:
      fatalError("extended data is too long")
    }
    bytes.append(UInt8(bitPattern: type))
    bytes += data

    _addedElement()
  }
}

@available(*, unavailable)
extension MsgPackEncoder: Sendable { }

internal func _safeUInt32ToInt(_ x: UInt32) -> Int? {
  return Int(exactly: x)
}

enum MsgPackError : Swift.Error {
  case decodeFailed
}


// MARK: MessagePack Decoder


/// A decoder for MessagePack.
///
/// This decoder provides a StAX-like interface.
public final class MsgPackDecoder: Decoder {
  // FIXME: This should be a Generator.
  // Currently it is not for performance reasons (StdlibUnittest
  // code can not be specialized).
  //
  // Or maybe not, since the caller might want to know how many
  // bytes were consumed.
  internal let _bytes: ArraySlice<UInt8>

  internal var _consumedCount: Int = 0

  public var consumedCount: Int {
    return _consumedCount
  }

  public init(_ bytes: ArraySlice<UInt8>) {
    self._bytes = bytes
  }

  internal func _fail() throws -> Never  {
    throw MsgPackError.decodeFailed
  }

  internal func _failIf(_ fn: () throws -> Bool) throws {
    if try fn() { try _fail() }
  }

  internal func _unwrapOrFail<T>(_ maybeValue: Optional<T>) throws -> T {
    if let value = maybeValue {
      return value
    }
    try _fail()
  }

  internal func _haveNBytes(_ count: Int) throws {
    try _failIf { _bytes.count < _consumedCount + count }
  }

  internal func _consumeByte() throws -> UInt8 {
    try _haveNBytes(1)
    let result = _bytes[_consumedCount]
    _consumedCount += 1
    return result
  }

  internal func _consumeByteIf(_ byte: UInt8) throws {
    try _failIf { try _consumeByte() != byte }
  }

  internal func _readBigEndianUInt16() throws -> UInt16 {
    var result: UInt16 = 0
    for _ in 0..<2 {
      result <<= 8
      result |= UInt16(try _consumeByte())
    }
    return result
  }

  internal func _readBigEndianUInt32() throws -> UInt32 {
    var result: UInt32 = 0
    for _ in 0..<4 {
      result <<= 8
      result |= UInt32(try _consumeByte())
    }
    return result
  }

  internal func _readBigEndianInt64() throws -> Int64 {
    let result = try _readBigEndianUInt64()
    return Int64(bitPattern: result)
  }

  internal func _readBigEndianUInt64() throws -> UInt64 {
    var result: UInt64 = 0
    for _ in 0..<8 {
      result <<= 8
      result |= UInt64(try _consumeByte())
    }
    return result
  }

  internal func _rewind<T>(
    _ code: () throws -> T
  ) -> T? {
    let originalPosition = _consumedCount
    do {
      return try code()
    } catch _ as MsgPackError {
      // MsgPack deserialization error.  Back up to the old position and return nil.
      _consumedCount = originalPosition
      return nil
    } catch {
      // Unexpected error.  Back up to the old position and return nil.
      // This used to preconditionFailure() but now it fails gracefully.
      _consumedCount = originalPosition
      return nil
    }
  }

  public func readInt64() -> Int64? {
    return _rewind {
      try _consumeByteIf(0xd3)
      return try _readBigEndianInt64()
    }
  }

  public func readUInt64() -> UInt64? {
    return _rewind {
      try _consumeByteIf(0xcf)
      return try _readBigEndianUInt64()
    }
  }

    public func readByte() -> UInt8? {
        return _rewind {
            try _consumeByteIf(0xe0)
            return try _consumeByte()
        }
    }

  public func readNil() -> Bool {
    let value: Bool? = _rewind {
      try _consumeByteIf(0xc0)
      return true
    }
    // .Some(true) means nil, nil means fail...
    return value != nil
  }

  public func readBool() -> Bool? {
    return _rewind {
      switch try _consumeByte() {
      case 0xc2:
        return false
      case 0xc3:
        return true
      default:
        try _fail()
      }
    }
  }

  public func readFloat32() -> Float32? {
    return _rewind {
      try _consumeByteIf(0xca)
      let bitPattern = try _readBigEndianUInt32()
      return Float32(bitPattern: bitPattern)
    }
  }

  public func readFloat64() -> Float64? {
    return _rewind {
      try _consumeByteIf(0xcb)
      let bitPattern = try _readBigEndianUInt64()
      return Float64(bitPattern: bitPattern)
    }
  }

  internal func _consumeBytes(_ length: Int) throws -> [UInt8] {
    try _haveNBytes(length)
    let result = _bytes[_consumedCount..<_consumedCount + length]
    _consumedCount += length
    return [UInt8](result)
  }

  public func readString() -> String? {
    return _rewind {
      let length: Int
      switch try _consumeByte() {
      case let byte where byte & 0b1110_0000 == 0b1010_0000:
        // fixstr
        length = Int(byte & 0b0001_1111)
      case 0xd9:
        // str8
        let count = try _consumeByte()
        // Reject overlong encodings.
        try _failIf { count <= 0x1f }
        length = Int(count)
      case 0xda:
        // str16
        let count = try _readBigEndianUInt16()
        // Reject overlong encodings.
        try _failIf { count <= 0xff }
        length = Int(count)
      case 0xdb:
        // str32
        let count = try _readBigEndianUInt32()
        // Reject overlong encodings.
        try _failIf { count <= 0xffff }
        length = Int(count)
      default:
        try _fail()
      }
      let utf8 = try _consumeBytes(length)
      return String(decoding: utf8, as: Unicode.UTF8.self)
    }
  }

  public func readBinary() -> [UInt8]? {
    return _rewind {
      let length: Int
      switch try _consumeByte() {
      case 0xc4:
        // bin8
        length = Int(try _consumeByte())
      case 0xc5:
        // bin16
        let count = try _readBigEndianUInt16()
        // Reject overlong encodings.
        try _failIf { count <= 0xff }
        length = Int(count)
      case 0xc6:
        // bin32
        let count = try _readBigEndianUInt32()
        // Reject overlong encodings.
        try _failIf { count <= 0xffff }
        length = Int(count)
      default:
        try _fail()
      }
      return try _consumeBytes(length)
    }
  }

  public func readBeginArray() -> Int? {
    return _rewind {
      switch try _consumeByte() {
      case let byte where byte & 0b1111_0000 == 0b1001_0000:
        // fixarray
        return Int(byte & 0b0000_1111)
      case 0xdc:
        // array16
        let length = try _readBigEndianUInt16()
        // Reject overlong encodings.
        try _failIf { length <= 0xf }
        return Int(length)
      case 0xdd:
        // array32
        let length = try _readBigEndianUInt32()
        // Reject overlong encodings.
        try _failIf { length <= 0xffff }
        return try _unwrapOrFail(_safeUInt32ToInt(length))
      default:
        try _fail()
      }
    }
  }

  public func readArray<T>(_ decodeElement: () throws -> T) -> [T]? {
    guard let count = self.readBeginArray() else { return nil }

    // If count is 0, then return an empty array.
    guard count > 0 else { return [T]() }

    // Otherwise decode the array.  If any items cannot be decoded as expected, then return nil as the entire array is considered to be bad.
    var array = [T]()
    array.reserveCapacity(count)
    for _ in 1...count
    {
      guard let element = try? decodeElement() else { return nil }
      array.append(element)
    }
    return array
  }

  public func readBeginMap() -> Int? {
    return _rewind {
      switch try _consumeByte() {
      case let byte where byte & 0b1111_0000 == 0b1000_0000:
        // fixarray
        return Int(byte & 0b0000_1111)
      case 0xde:
        // array16
        let length = try _readBigEndianUInt16()
        // Reject overlong encodings.
        try _failIf { length <= 0xf }
        return Int(length)
      case 0xdf:
        // array32
        let length = try _readBigEndianUInt32()
        // Reject overlong encodings.
        try _failIf { length <= 0xffff }
        return try _unwrapOrFail(_safeUInt32ToInt(length))
      default:
        try _fail()
      }
    }
  }

  public func readDictionary<Tk, Tv>(_ decodeKey: () throws -> Tk, _ decodeValue: () throws -> Tv) -> [Tk: Tv]? {
    guard let count = self.readBeginMap() else { return nil }

    // If count is 0, then return an empty dictionary.
    guard count > 0 else { return [Tk: Tv]() }

    // Otherwise, decode the dictionary.
    var dict = [Tk: Tv]()
    for _ in 1...count
    {
      guard let key = try? decodeKey() else { return nil }
      guard let value = try? decodeValue() else { return nil }
      dict[key] = value
    }
    return dict
  }

  public func readExtended() -> (type: Int8, data: [UInt8])? {
    return _rewind {
      let length: Int
      switch try _consumeByte() {
      case 0xd4:
        // fixext1
        length = 1
      case 0xd5:
        // fixext2
        length = 2
      case 0xd6:
        // fixext4
        length = 4
      case 0xd7:
        // fixext8
        length = 8
      case 0xd8:
        // fixext16
        length = 16
      case 0xc7:
        // ext8
        let count = try _consumeByte()
        // Reject overlong encodings.
        try _failIf {
          count == 1 ||
          count == 2 ||
          count == 4 ||
          count == 8 ||
          count == 16
        }
        length = Int(count)
      case 0xc8:
        // ext16
        let count = try _readBigEndianUInt16()
        try _failIf { count <= 0xff }
        length = Int(count)
      case 0xc9:
        // ext32
        let count = try _readBigEndianUInt32()
        // Reject overlong encodings.
        try _failIf { count <= 0xffff }
        length = Int(count)
      default:
        try _fail()
      }
      let type = try _consumeByte()
      let result = try _consumeBytes(length)
      return (Int8(bitPattern: type), result)
    }
  }
}

@available(*, unavailable)
extension MsgPackDecoder: Sendable { }

/// There was additional code to support a DOM-like representation of a MessagePack object, but it has been removed since we have no plans to use it.
