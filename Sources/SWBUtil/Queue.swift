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

/// A queue data structure with O(1) FIFO operations.
public struct Queue<T>: ExpressibleByArrayLiteral, RandomAccessCollection {
    public typealias Element = T

    public typealias Indices = Range<Int>

    /// The backing array used with wrapped access.
    ///
    /// This is rather inefficient because we are not implemented at a low-level enough fashion to be able to avoid storing optionals here. We could also simply not deinit the items, but that may lead to unexpected deinit behavior for clients.
    ///
    /// In particular, there are two problems here:
    /// 1. By storing optionals, we are wasting space and forcing additional initialization of the contents.
    /// 2. We aren't taking full advantage of the array's growable capacity
    private var array: Array<T?> = [nil]

    /// The virtual index of the head of the queue.
    ///
    /// The concrete index of this item in the array is at array[head % array.count].
    ///
    /// - Invariant: head <= tail
    /// - Invariant: isEmpty <=> head == tail
    private var head: Int = 0

    /// The virtual index of the tail of the queue.
    ///
    /// The concrete index of this item in the array is at array[tail % array.count].
    private var tail: Int = 0

    /// Creates an empty queue.
    public init() {
        self.array = [nil]
        self.head = 0
        self.tail = 0
    }

    /// Creates a queue with the given items.
    public init<S: Sequence>(_ sequence: S) where S.Element == Element {
        let array = Array(sequence)
        // A Queue always has at least one element, that being nil if not a real element.
        self.array = array.isEmpty ? [nil] : array
        self.head = 0
        self.tail = array.count
    }

    /// Creates a queue with the given items.
    public init(arrayLiteral elements: Element...) {
        self.init(elements)
    }

    /// The number of elements in the queue.
    public var count: Int {
        return tail - head
    }

    /// Check if the queue is empty.
    public var isEmpty: Bool {
        return head == tail
    }

    /// Append an element to the queue.
    public mutating func append(_ item: Element) {
        // Grow the array if necessary.
        if count == array.count {
            grow()
        }

        // Insert and move the tail.
        array[tail % array.count] = item
        tail += 1
    }

    /// Append a sequence of elements to the queue.
    public mutating func append<S>(contentsOf newElements: S) where Element == S.Iterator.Element, S : Sequence {
        for item in newElements {
            append(item)
        }
    }

    /// If a queue has N elements, their logical indexes are 0..<N, but their concrete indexes depend on the current state of `array` and `head`.
    private func concreteIndex(forLogicalIndex index: Int) -> Int {
        return (head + index) % array.count
    }

    /// Remove and return the element at the head of the queue, or nil if the queue is empty.
    public mutating func popFirst() -> Element? {
        // Check
        guard !self.isEmpty else { return nil }

        // Fetch
        let index = concreteIndex(forLogicalIndex: 0)
        let result = array[index]!

        // Pop
        array[index] = nil
        head += 1

        // Return
        return result
    }

    /// Resize the backing storage for items.
    ///
    /// - Postcondition: count < array.count
    private mutating func grow() {
        let n = count
        let priorArray = array
        array = Array(repeating: nil, count: array.count * 2)
        for i in 0..<n {
            array[i] = priorArray[(head + i) % priorArray.count]
        }
        head = 0
        tail = n
        assert(count < array.count)
    }

    // MARK: - RandomAccessCollection conformance

    public var startIndex: Int {
        return 0
    }

    public var endIndex: Int {
        return count
    }

    public func index(after i: Int) -> Int {
        return i + 1
    }

    public subscript(index: Int) -> Element {
        precondition(index < count)
        return array[concreteIndex(forLogicalIndex: index)]!
    }
}

extension Queue: Sendable where T: Sendable {}
