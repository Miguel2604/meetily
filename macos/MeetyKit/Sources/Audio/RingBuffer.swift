import Synchronization

/// Lock-free single-producer/single-consumer float ring (D7). The producer is a real-time
/// audio callback: `write` never allocates, locks or logs. Samples that do not fit are dropped and counted.
public final class RingBuffer: @unchecked Sendable { // synchronized by the two atomics
    private let storage: UnsafeMutablePointer<Float>
    private let mask: Int
    private let head = Atomic<Int>(0) // total samples written (producer-owned)
    private let tail = Atomic<Int>(0) // total samples read (consumer-owned)
    private let dropped = Atomic<Int>(0)

    public let capacity: Int

    /// `capacity` is rounded up to a power of two.
    public init(capacity: Int) {
        var size = 1
        while size < capacity { size <<= 1 }
        self.capacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit { storage.deallocate() }

    public var available: Int { head.load(ordering: .acquiring) - tail.load(ordering: .acquiring) }
    public var droppedSamples: Int { dropped.load(ordering: .relaxed) }

    /// Producer side. Returns how many samples were stored.
    @discardableResult
    public func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        write(count: count) { source[$0] }
    }

    /// Producer side, computing each sample (e.g. a downmix) in place. `sample` must not allocate.
    @inline(__always) @discardableResult
    public func write(count: Int, sample: (Int) -> Float) -> Int {
        let h = head.load(ordering: .relaxed)
        let free = capacity - (h - tail.load(ordering: .acquiring))
        let n = min(count, free)
        for i in 0..<n { storage[(h + i) & mask] = sample(i) }
        head.store(h + n, ordering: .releasing)
        if n < count { dropped.add(count - n, ordering: .relaxed) }
        return n
    }

    /// Consumer side. Returns how many samples were copied.
    public func read(into destination: UnsafeMutablePointer<Float>, max: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let n = Swift.min(max, head.load(ordering: .acquiring) - t)
        for i in 0..<n { destination[i] = storage[(t + i) & mask] }
        tail.store(t + n, ordering: .releasing)
        return n
    }

    /// Consumer side: everything currently buffered.
    public func drain() -> [Float] {
        let n = available
        guard n > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: n) { buffer, count in
            count = read(into: buffer.baseAddress!, max: n)
        }
    }
}
