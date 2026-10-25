import XCTest
@testable import MemoCore

final class LocalFilesTests: XCTestCase {
    func testEnumeratedRecordingDeletesUsingRelativeBaseURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("录像.mp4")
        try Data("fixture".utf8).write(to:file)
        let relative = URL(fileURLWithPath:"录像.mp4",relativeTo:root)
        XCTAssertTrue(LocalFiles.contains(relative,in:root))
        try LocalFiles.remove(relative,in:root)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        XCTAssertThrowsError(try LocalFiles.remove(relative,in:root))
    }
    func testBatchAcrossRecordingAndWorkDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let records = root.appendingPathComponent("Recordings",isDirectory:true)
        let works = root.appendingPathComponent("Works",isDirectory:true)
        let album = works.appendingPathComponent("album",isDirectory:true)
        for dir in [records,album] { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }
        for file in [records.appendingPathComponent("a.mp4"),album.appendingPathComponent("b.jpg")] {
            try Data("fixture".utf8).write(to:file)
            if LocalFiles.contains(file,in:records) { try LocalFiles.remove(file,in:records) }
            else { try LocalFiles.remove(file,in:works,recursive:true) }
            XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
        }
    }
    func testRejectSiblingPrefixAndDirectoryItself() throws {
        let root = URL(fileURLWithPath:"/tmp/MemoWorks",isDirectory:true)
        XCTAssertFalse(LocalFiles.contains(URL(fileURLWithPath:"/tmp/MemoWorksOther/a.mp4"),in:root,recursive:true))
        XCTAssertFalse(LocalFiles.contains(root,in:root,recursive:true))
        XCTAssertFalse(LocalFiles.contains(URL(fileURLWithPath:"/tmp/MemoWorks/a/b.jpg"),in:root))
    }
    func testRejectSymlinkEscapingLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let outside = root.appendingPathComponent("outside.mp4")
        let library = root.appendingPathComponent("Recordings",isDirectory:true)
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        try Data("keep".utf8).write(to:outside)
        let link = library.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:outside)
        XCTAssertThrowsError(try LocalFiles.remove(link,in:library))
        XCTAssertTrue(FileManager.default.fileExists(atPath:outside.path))
    }
}
