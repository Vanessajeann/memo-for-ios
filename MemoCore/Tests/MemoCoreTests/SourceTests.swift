import XCTest
@testable import MemoCore

final class SourceTests: XCTestCase {
    func testAndroidBackupRoundTripKeepsHeadersAndQuality() throws {
        let json = #"{"format":"MemoSources","version":1,"sources":[{"id":"old","name":"test","url":"https://example.com/live.m3u8","referer":"https://example.com/","cookie":"sample=fixture","agent":"Memo-test","qualityId":10000}]}"#
        let b = try SourceBackup.decode(Data(json.utf8))
        let s = try XCTUnwrap(b.sources.first).validated()
        XCTAssertEqual(s.headers["Cookie"], "sample=fixture")
        XCTAssertEqual(s.qualityId, 10000)
        XCTAssertEqual(try SourceBackup.decode(JSONEncoder().encode(b)).sources, b.sources)
    }
    func testOlderAndroidBackupDefaults() throws {
        let b = try SourceBackup.decode(Data(#"{"format":"MemoSources","version":1,"sources":[{"url":"rtmp://example.com/live"}]}"#.utf8))
        XCTAssertEqual(b.sources[0].qualityId, 0)
        XCTAssertEqual(try b.sources[0].validated().name, "未命名直播")
    }
    func testShareAndProtocols() throws {
        XCTAssertEqual(try Link.extract("分享【测试】 https://v.douyin.com/fixture/ 正在直播"), "https://v.douyin.com/fixture/")
        for scheme in ["http", "https", "rtmp", "rtmps", "rtsp"] {
            XCTAssertEqual(try Link.extract("\(scheme)://example.com/live"), "\(scheme)://example.com/live")
        }
        XCTAssertThrowsError(try Link.extract("file:///etc/passwd"))
        XCTAssertThrowsError(try Link.extract("https://user:secret@example.com/live"))
        XCTAssertEqual(Link.platform("https://douyin.com.attacker.example/live"), "媒体直链")
    }
    func testHeaderInjectionRejected() {
        var s = Source(); s.url = "https://example.com/live"; s.cookie = "a=b\r\nInjected: yes"
        XCTAssertThrowsError(try s.validated()) { XCTAssertEqual($0 as? MemoError, .invalidHeader) }
    }
    func testLimitEditAndDuplicate() throws {
        var list: [Source] = []
        for i in 0..<9 { var s = Source(); s.url = "https://example.com/\(i)"; list = try SourceList.upsert(s, into: list) }
        var extra = Source(); extra.url = "https://example.com/extra"
        XCTAssertThrowsError(try SourceList.upsert(extra, into: list)) { XCTAssertEqual($0 as? MemoError, .capacity) }
        var edit = list[0]; edit.name = "edited"
        XCTAssertEqual(try SourceList.upsert(edit, into: list).first?.name, "edited")
        extra.url = list[0].url
        XCTAssertThrowsError(try SourceList.upsert(extra, into: list)) { XCTAssertEqual($0 as? MemoError, .duplicate) }
    }
    func testBackupRejectsUnknownVersionAndOversizedData() {
        for j in [#"{"format":"wrong","version":1,"sources":[]}"#, #"{"format":"MemoSources","version":2,"sources":[]}"#] {
            XCTAssertThrowsError(try SourceBackup.decode(Data(j.utf8)))
        }
        XCTAssertThrowsError(try SourceBackup.decode(Data(repeating: 32, count: 1_000_001)))
    }
    func testRecoveryDoesNotRetryPermissionsOrFullDisk() {
        XCTAssertFalse(RecordingPolicy.retry(wanted: true, attempts: 0, reconnect: true, online: false, logs: "HTTP error 403 Forbidden"))
        XCTAssertFalse(RecordingPolicy.retry(wanted: true, attempts: 0, reconnect: true, online: false, logs: "No space left on device"))
        XCTAssertTrue(RecordingPolicy.retry(wanted: true, attempts: 0, reconnect: false, online: true, logs: "Connection reset by peer"))
        XCTAssertFalse(RecordingPolicy.retry(wanted: true, attempts: 8, reconnect: true, online: true, logs: "timeout"))
        XCTAssertEqual(RecordingPolicy.delay(attempt: 8), 30)
        XCTAssertFalse(RecordingPolicy.stalled(now: 100, lastProgress: 0, capturing: true, stopping: true))
    }
}
