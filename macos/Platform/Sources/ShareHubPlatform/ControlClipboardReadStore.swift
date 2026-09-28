import Cocoa

struct ControlClipboardReadSnapshot: Equatable {
    let sequence: Int64
    let text: String?
}

enum ControlClipboardReadError: Error {
    case busy, invalidScope, staleScope, expired, clipboardUnavailable
}

/// One process-local control lease. All calls run on the AppKit main thread.
/// This side only observes plain text; no operation writes or clears the OS pasteboard.
final class ControlClipboardReadStore {
    typealias Clock = () -> UInt64
    typealias Sequence = () -> Int?
    typealias Reader = () throws -> String?

    init(clock: @escaping Clock = { ConnectionSecurity.continuousMicros },
         sequence: @escaping Sequence = { NSPasteboard.general.changeCount },
         readText: @escaping Reader = { NSPasteboard.general.string(forType: .string) }) {
        self.clock = clock
        self.sequence = sequence
        self.readText = readText
    }

    private let clock: Clock
    private let sequence: Sequence
    private let readText: Reader
    private var nextLease: Int64 = 1
    private var lease: Int64 = 0
    private var deadlineMicros: UInt64 = 0
    private var epoch: Int64 = 0
    private var controllerRevision: Int64 = 0
    private var targetRevision: Int64 = 0
    private var observedSequence: Int64 = 0

    var isActive: Bool { lease != 0 }

    private func currentSequence() -> Int64? {
        guard let raw = sequence(), raw >= 0, raw < Int(UInt32.max) else { return nil }
        // NSPasteboard starts at zero; the Dart contract uses positive sequences.
        return Int64(raw) + 1
    }

    func open(deadlineMicros: Int64, epoch: Int64,
              controllerRevision: Int64, targetRevision: Int64) throws -> Int64 {
        guard lease == 0 else { throw ControlClipboardReadError.busy }
        let now = clock()
        guard deadlineMicros > 0, epoch > 0, controllerRevision > 0,
              targetRevision > 0, now > 0, now < UInt64(deadlineMicros),
              nextLease < Int64.max, let initial = currentSequence() else {
            throw ControlClipboardReadError.invalidScope
        }
        lease = nextLease
        nextLease += 1
        self.deadlineMicros = UInt64(deadlineMicros)
        self.epoch = epoch
        self.controllerRevision = controllerRevision
        self.targetRevision = targetRevision
        observedSequence = initial
        return lease
    }

    private func require(lease: Int64, epoch: Int64,
                         controllerRevision: Int64, targetRevision: Int64) throws {
        guard self.lease != 0, self.lease == lease, self.epoch == epoch,
              self.controllerRevision == controllerRevision,
              self.targetRevision == targetRevision else {
            throw ControlClipboardReadError.staleScope
        }
        let now = clock()
        guard now > 0, now < deadlineMicros else {
            shutdown()
            throw ControlClipboardReadError.expired
        }
    }

    func read(lease: Int64, epoch: Int64,
              controllerRevision: Int64, targetRevision: Int64) throws -> ControlClipboardReadSnapshot {
        try require(lease: lease, epoch: epoch,
                    controllerRevision: controllerRevision, targetRevision: targetRevision)
        guard let before = currentSequence() else { throw ControlClipboardReadError.clipboardUnavailable }
        guard before >= observedSequence else {
            shutdown()
            throw ControlClipboardReadError.clipboardUnavailable
        }
        let text: String?
        do { text = try readText() }
        catch { throw ControlClipboardReadError.clipboardUnavailable }
        let validText = text.map { $0.utf8.count <= 32768 && !$0.contains("\0") } ?? true
        guard let after = currentSequence(), before == after, validText else {
            throw ControlClipboardReadError.clipboardUnavailable
        }
        try require(lease: lease, epoch: epoch,
                    controllerRevision: controllerRevision, targetRevision: targetRevision)
        observedSequence = after
        return ControlClipboardReadSnapshot(sequence: after, text: text)
    }

    /// Returns a notification bit only. The authenticated owner rechecks its
    /// scope and reads text separately before publishing a message.
    func pollChanged() -> Bool {
        guard lease != 0 else { return false }
        let now = clock()
        guard now > 0, now < deadlineMicros, let current = currentSequence() else {
            shutdown()
            return false
        }
        guard current >= observedSequence else {
            shutdown()
            return false
        }
        if current == observedSequence { return false }
        observedSequence = current
        return true
    }

    func close(lease: Int64) throws {
        guard self.lease != 0, self.lease == lease else {
            throw ControlClipboardReadError.staleScope
        }
        shutdown()
    }

    func shutdown() {
        lease = 0
        deadlineMicros = 0
        epoch = 0
        controllerRevision = 0
        targetRevision = 0
        observedSequence = 0
    }
}
