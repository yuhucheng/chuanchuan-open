import Cocoa

struct ControlClipboardReadSnapshot: Equatable {
    let sequence: Int64
    let text: String?
}

enum ControlClipboardWriteStatus: Equatable {
    case written, conflict, unknown
}

struct ControlClipboardWriteResult: Equatable {
    let status: ControlClipboardWriteStatus
    let sequence: Int64?
}

enum ControlClipboardReadError: Error {
    case busy, invalidScope, staleScope, expired, invalidText, clipboardUnavailable
}

/// One process-local control lease. All calls run on the AppKit main thread.
/// A conditional write checks the same exact scope and change sequence as reads.
final class ControlClipboardReadStore {
    typealias Clock = () -> UInt64
    typealias Sequence = () -> Int?
    typealias Reader = () throws -> String?
    typealias Writer = (String) throws -> Bool

    init(clock: @escaping Clock = { ConnectionSecurity.continuousMicros },
         sequence: @escaping Sequence = { NSPasteboard.general.changeCount },
         readText: @escaping Reader = { NSPasteboard.general.string(forType: .string) },
         writeText: @escaping Writer = { text in
             let pasteboard = NSPasteboard.general
             pasteboard.clearContents()
             return pasteboard.setString(text, forType: .string)
         }) {
        self.clock = clock
        self.sequence = sequence
        self.readText = readText
        self.writeText = writeText
    }

    private let clock: Clock
    private let sequence: Sequence
    private let readText: Reader
    private let writeText: Writer
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

    func write(lease: Int64, epoch: Int64, controllerRevision: Int64,
               targetRevision: Int64, expectedSequence: Int64,
               text: String) throws -> ControlClipboardWriteResult {
        try require(lease: lease, epoch: epoch,
                    controllerRevision: controllerRevision, targetRevision: targetRevision)
        guard expectedSequence > 0, expectedSequence <= Int64(UInt32.max),
              text.utf8.count <= 32768, !text.contains("\0") else {
            throw ControlClipboardReadError.invalidText
        }
        guard let current = currentSequence(), current >= observedSequence else {
            shutdown()
            return ControlClipboardWriteResult(status: .unknown, sequence: nil)
        }
        guard current == expectedSequence else {
            return ControlClipboardWriteResult(status: .conflict, sequence: nil)
        }
        // AppKit calls from this runner are serial on the main thread. Another
        // process may still write concurrently; report the observed OS order.
        let didWrite: Bool
        do { didWrite = try writeText(text) }
        catch {
            shutdown()
            return ControlClipboardWriteResult(status: .unknown, sequence: nil)
        }
        guard didWrite, let written = currentSequence(), written > current else {
            shutdown()
            return ControlClipboardWriteResult(status: .unknown, sequence: nil)
        }
        observedSequence = written
        return ControlClipboardWriteResult(status: .written, sequence: written)
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
