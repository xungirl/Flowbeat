import XCTest
@testable import FlowbeatCore

final class SessionArchiveTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func writeSession(startingAt t: TimeInterval, name: String) throws -> URL {
        let s = [FocusSample(t: Date(timeIntervalSince1970: t), heartRate: 70, motion: 0, score: 90, label: nil)]
        let url = tmp.appendingPathComponent(name)
        try FlowbeatJSON.sessionEncoder.encode(SessionRecord(samples: s, windows: [], judgments: [], review: nil)).write(to: url)
        return url
    }

    func testImportThenLoadNewestFirst() throws {
        let archive = SessionArchive(directory: tmp.appendingPathComponent("sessions"))
        try archive.importFile(at: try writeSession(startingAt: 1000, name: "a.json"))
        try archive.importFile(at: try writeSession(startingAt: 5000, name: "b.json"))
        let all = archive.loadAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.url.lastPathComponent, "b.json")
    }

    func testReimportSameNameReplaces() throws {
        let archive = SessionArchive(directory: tmp.appendingPathComponent("sessions"))
        try archive.importFile(at: try writeSession(startingAt: 1000, name: "x.json"))
        try archive.importFile(at: try writeSession(startingAt: 2000, name: "x.json"))
        XCTAssertEqual(archive.loadAll().count, 1)
    }

    func testRejectsCorruptFileAndPathTraversal() throws {
        let archive = SessionArchive(directory: tmp.appendingPathComponent("sessions"))
        let bad = tmp.appendingPathComponent("bad.json")
        try Data("not json".utf8).write(to: bad)
        XCTAssertThrowsError(try archive.importFile(at: bad))
        let dest = try archive.importFile(at: try writeSession(startingAt: 1, name: "ok.json"), name: "../../evil")
        XCTAssertEqual(dest.deletingLastPathComponent().lastPathComponent, "sessions")
        XCTAssertEqual(dest.lastPathComponent, "evil.json")
    }

    func testLoadSkipsUndecodableFiles() throws {
        let dir = tmp.appendingPathComponent("sessions")
        let archive = SessionArchive(directory: dir)
        try archive.importFile(at: try writeSession(startingAt: 1, name: "ok.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("junk.json"))
        XCTAssertEqual(archive.loadAll().count, 1)
    }

    func testMissingDirectoryLoadsEmpty() {
        XCTAssertTrue(SessionArchive(directory: tmp.appendingPathComponent("nope")).loadAll().isEmpty)
    }
}
