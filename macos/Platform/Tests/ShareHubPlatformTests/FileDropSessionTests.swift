import Foundation
import XCTest
@testable import ShareHubPlatform

final class FileDropSessionTests: XCTestCase {
    private func onMain(_ action: () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.sync(execute: action) }
    }

    func testLocatePrecedesOpeningAndRejectReleasesCapabilities() {
        onMain {
            var locate: FileDropSession.Decision?
            var prepared: ((Result<[SelectedFileInfo], Error>) -> Void)?
            var decide: FileDropSession.Decision?
            var opened = 0, released: [String] = [], holds = 0
            let session = FileDropSession(
                locate: { x, y, reply in XCTAssertEqual(x, 4); XCTAssertEqual(y, 8); locate = reply },
                prepare: { _, completion in opened += 1; prepared = completion },
                release: { released += $0.map(\.token) },
                offer: { files, _, _, reply in XCTAssertEqual(files.first?.token, "token"); decide = reply },
                onError: { XCTFail("unexpected error") },
                holdURLs: { _ in holds += 1; return { holds -= 1 } })
            let urls = [URL(fileURLWithPath: "/selected/file")]
            XCTAssertFalse(session.accept(urls, x: 4, y: 8))
            session.listen()
            XCTAssertTrue(session.accept(urls, x: 4, y: 8))
            XCTAssertFalse(session.accept(urls, x: 4, y: 8))
            XCTAssertEqual(opened, 0); XCTAssertEqual(holds, 1)
            locate?(true)
            XCTAssertEqual(opened, 1)
            prepared?(.success([SelectedFileInfo(token: "token", name: "file", size: 3)]))
            XCTAssertEqual(holds, 0)
            decide?(false); decide?(false)
            XCTAssertEqual(released, ["token"])
            XCTAssertTrue(session.ready)
            session.close()
        }
    }

    func testCancelledPreparationCannotDeliverToNewListener() {
        onMain {
            var prepared: ((Result<[SelectedFileInfo], Error>) -> Void)?
            var released: [String] = [], holds = 0
            let session = FileDropSession(
                locate: { _, _, reply in reply(true) },
                prepare: { _, completion in prepared = completion },
                release: { released += $0.map(\.token) },
                offer: { _, _, _, _ in XCTFail("cancelled offer delivered") },
                onError: { XCTFail("cancelled failure displayed") },
                holdURLs: { _ in holds += 1; return { holds -= 1 } })
            session.listen()
            XCTAssertTrue(session.accept([URL(fileURLWithPath: "/file")], x: 0, y: 0))
            session.cancel(); session.listen()
            XCTAssertEqual(holds, 0)
            prepared?(.success([SelectedFileInfo(token: "old", name: "file", size: 1)]))
            XCTAssertEqual(released, ["old"])
            XCTAssertTrue(session.ready)
            session.close()
        }
    }

    func testAcceptanceCrossingCancelKeepsDartOwnershipAndCloseRejectsNewWork() {
        onMain {
            var decide: FileDropSession.Decision?
            var released: [String] = []
            let session = FileDropSession(
                locate: { _, _, reply in reply(true) },
                prepare: { _, completion in completion(.success([SelectedFileInfo(token: "kept", name: "file", size: 0)])) },
                release: { released += $0.map(\.token) },
                offer: { _, _, _, reply in decide = reply }, onError: {}, holdURLs: { _ in {} })
            session.listen()
            XCTAssertTrue(session.accept([URL(fileURLWithPath: "/file")], x: 0, y: 0))
            session.cancel(); decide?(true); session.close(); decide?(false)
            XCTAssertTrue(released.isEmpty)
            XCTAssertFalse(session.accept([URL(fileURLWithPath: "/file")], x: 0, y: 0))
        }
    }

    func testLateCompletionAfterCloseReleasesAndBoundsRejectWithoutOpening() {
        onMain {
            var prepared: ((Result<[SelectedFileInfo], Error>) -> Void)?
            var released: [String] = [], opened = 0
            let session = FileDropSession(
                locate: { _, _, reply in reply(true) },
                prepare: { _, completion in opened += 1; prepared = completion },
                release: { released += $0.map(\.token) },
                offer: { _, _, _, _ in XCTFail("closed offer delivered") }, onError: {}, holdURLs: { _ in {} })
            session.listen()
            XCTAssertFalse(session.accept([], x: 0, y: 0))
            XCTAssertFalse(session.accept(Array(repeating: URL(fileURLWithPath: "/file"), count: 65), x: 0, y: 0))
            XCTAssertFalse(session.accept([URL(string: "https://example.invalid/file")!], x: 0, y: 0))
            XCTAssertEqual(opened, 0)
            XCTAssertTrue(session.accept([URL(fileURLWithPath: "/file")], x: 0, y: 0))
            session.close()
            prepared?(.success([SelectedFileInfo(token: "late", name: "file", size: 1)]))
            XCTAssertEqual(released, ["late"])
        }
    }
}
