import XCTest
@testable import MemoCore

final class PlatformTests:XCTestCase {
    let sec = "MS4SyntheticAuthor123456"
    func bytes(_ o:[String:Any])throws->Data { try JSONSerialization.data(withJSONObject:o) }
    func addr(_ url:String = "https://v.douyinvod.com/original.mp4",width:Int = 1920,height:Int = 1080)->[String:Any] { ["url_list":[url],"width":width,"height":height] }
    func post()->[String:Any] { ["aweme_id":"7690000000000000001","desc":"synthetic","author":["sec_uid":sec,"nickname":"fixture"],"video":["play_addr":addr()]] }
    func track(_ url:String = "https://fixture.bilivideo.com/video.m4s",codec:String = "avc1.640028",bitrate:Int = 1000)->[String:Any] { ["id":80,"baseUrl":url,"codecs":codec,"bandwidth":bitrate,"width":1920,"height":1080] }
    func playback()->[String:Any] { ["support_formats":[["quality":120,"new_description":"4K","need_vip":true],["quality":80,"new_description":"1080P"]],"dash":["video":[track()],"audio":[track("https://fixture.bilivideo.com/audio.m4s",codec:"mp4a.40.2")]]] }
    func testDomainBoundaries() {
        XCTAssertTrue(Platform.douyin.official("webcast.amemv.com")); XCTAssertFalse(Platform.douyin.official("douyin.com.evil.example"))
        XCTAssertTrue(MediaURL.allowed("https://a.bilivideo.com/a",platform:.bilibili)); XCTAssertFalse(MediaURL.allowed("https://bilivideo.com.evil.example/a",platform:.bilibili))
        XCTAssertFalse(MediaURL.allowed("https://u:p@a.bilivideo.com/a",platform:.bilibili)); XCTAssertFalse(MediaURL.allowed("http://a.bilivideo.com/a",platform:.bilibili)); XCTAssertFalse(MediaURL.allowed("https://a.bilivideo.com:8443/a",platform:.bilibili))
    }
    func testWatermarkedCandidatesAreExcluded() {
        for u in ["https://v.douyinvod.com/playwm/a","https://v.douyinvod.com/a?is_watermark=1","https://v.douyinvod.com/tplv-dy-watermark/a"] { XCTAssertFalse(MediaURL.original(u,platform:.douyin)) }
        XCTAssertTrue(MediaURL.original("https://v.douyinvod.com/a?watermark=0",platform:.douyin))
    }
    func testAuthorIdentityAndBiliEntrypoints()throws {
        XCTAssertEqual(MediaURL.secID("https://www.douyin.com/user/\(sec)"),sec)
        XCTAssertEqual(MediaURL.secID("https://evil.example/user/\(sec)"),"")
        XCTAssertEqual(try Bilibili.link("BV1234567890"),"https://www.bilibili.com/video/BV1234567890")
        XCTAssertEqual(Bilibili.videoID("https://www.bilibili.com/video/av123/"),"av123")
        XCTAssertEqual(Bilibili.userID("https://space.bilibili.com/123"),"123")
        XCTAssertEqual(Bilibili.liveID("https://live.bilibili.com/blanc/123"),"123")
        XCTAssertThrowsError(try Bilibili.link("https://bilibili.com.evil.example/video/BV1234567890"))
    }
    func testDouyinOriginalSelectionUsesResolutionBeforeBitrate()throws {
        var o = post(), v = o["video"] as! [String:Any]
        v["bit_rate"] = [["bit_rate":9999999,"play_addr":addr("https://v.douyinvod.com/small.mp4",width:640,height:360)],["bit_rate":2000000,"play_addr":addr("https://v.douyinvod.com/large.mp4",width:3840,height:2160)]]; o["video"] = v
        let w = try XCTUnwrap(Douyin.work(o)); XCTAssertEqual(w.media?.width,3840); XCTAssertTrue(w.media?.urls.first?.contains("large") == true)
    }
    func testEncryptedVideoNotDownloadable()throws {
        var o = post(), v = o["video"] as! [String:Any]; v["is_drm"] = 1; o["video"] = v
        XCTAssertFalse(try XCTUnwrap(Douyin.work(o)).downloadable)
    }
    func testAlbumKeepsOrderAndMissingPages()throws {
        var o = post(); o["images"] = [addr("https://p.douyinpic.com/first.webp"),["is_encrypt":1],addr("https://p.douyinpic.com/third.png")]
        let w = try XCTUnwrap(Douyin.work(o)); XCTAssertTrue(w.album); XCTAssertEqual(w.images.count,3); XCTAssertTrue(w.images[1].urls.isEmpty); XCTAssertFalse(w.downloadable); XCTAssertEqual(w.images[2].urls.first,"https://p.douyinpic.com/third.png")
    }
    func testAlbumOriginalPreferred()throws {
        var image = addr("https://p.douyinpic.com/small.webp",width:500,height:500); image["origin_image"] = addr("https://p.douyinpic.com/origin.jpg",width:2000,height:2000)
        var o = post(); o["images"] = [image]
        XCTAssertEqual(Douyin.work(o)?.images.first?.urls.first,"https://p.douyinpic.com/origin.jpg")
    }
    func testExactIDsDedupAndPagination()throws {
        let p = try Douyin.page(bytes(["status_code":0,"aweme_list":[post(),post()],"has_more":1,"max_cursor":"9876543210987654321"]),expected:sec)
        XCTAssertEqual(p.works.count,1); XCTAssertEqual(p.works[0].id,"7690000000000000001"); XCTAssertTrue(p.known); XCTAssertTrue(p.hasMore); XCTAssertEqual(p.cursor,"9876543210987654321")
    }
    func testWrongAuthorAndVerificationRejected()throws {
        XCTAssertThrowsError(try Douyin.page(bytes(["aweme_list":[post()]]),expected:"MS4OtherAuthor123"))
        XCTAssertThrowsError(try Douyin.page(bytes(["status_code":4,"aweme_list":[]]),expected:sec))
        XCTAssertThrowsError(try Douyin.page(Data("<html>verify</html>".utf8),expected:sec))
    }
    func testEmbeddedDoesNotInventPagination()throws {
        let p = try Douyin.embedded(bytes(["nested":["posts":[post()]]]),expected:sec)
        XCTAssertEqual(p.works.count,1); XCTAssertFalse(p.known); XCTAssertFalse(p.hasMore)
    }
    func testDouyinLiveRankAndLowPreview()throws {
        let p = try Douyin.live(bytes(["data":["room":["status":2,"owner":["nickname":"fixture"],"stream_url":["hls_pull_url_map":["origin":"https://fixture.example/origin.m3u8","sd1":"https://fixture.example/low.m3u8"],"flv_pull_url":["hd1":"https://fixture.example/hd.flv"]]]]]),roomID:"123456789012345")
        XCTAssertEqual(p.best?.label,"原画"); XCTAssertTrue(p.preview?.url.contains("low") == true)
    }
    func testLiveEndedNotReportedAsPlayable()throws {
        XCTAssertThrowsError(try Douyin.live(bytes(["data":["room":["status":4]]]),roomID:"123456789012345"))
        XCTAssertEqual(Douyin.roomID("https://webcast.amemv.com/reflow/123456789012345"),"123456789012345")
    }
    func testBiliPartsAndStableQualityIDs()throws {
        let parts = Bilibili.parts(["bvid":"BV1234567890","title":"fixture","pages":[["cid":123,"page":1,"part":"one"],["cid":124,"page":2,"part":"two"]]])
        XCTAssertEqual(parts.count,2); XCTAssertTrue(parts[1].title.contains("P2")); XCTAssertNotEqual(parts[0].id,parts[1].id)
        let qs = Bilibili.playback(playback()); XCTAssertEqual(qs[0].id,120); XCTAssertFalse(qs[0].available); XCTAssertTrue(qs[0].reason.contains("大会员")); XCTAssertTrue(qs[1].available)
        let w = try Bilibili.select(parts[0],quality:qs[1]); XCTAssertTrue(w.key.hasSuffix("_q80")); XCTAssertEqual(w.audio?.codec,"mp4a.40.2")
        XCTAssertThrowsError(try Bilibili.select(parts[0],quality:qs[0]))
    }
    func testBiliPrefersCompatibleCodecNotHighestBitrateAlone()throws {
        var p = playback(); p["dash"] = ["video":[track(codec:"av01.0.08M.08",bitrate:99999),track(codec:"avc1.640028",bitrate:1000)],"audio":[track(codec:"mp4a.40.2")]]
        XCTAssertEqual(Bilibili.playback(p).first(where:{$0.available})?.video?.codec,"avc1.640028")
    }
    func testPreviewDRMAndMissingAudioRejected() {
        for flag in ["is_preview","is_drm","is_drm_video","drm_tech_type"] { var p = playback(); p[flag] = 1; XCTAssertFalse(Bilibili.playback(p).contains(where:{$0.available})) }
        var p = playback(); p["dash"] = ["video":[track()]]; XCTAssertFalse(Bilibili.playback(p).contains(where:{$0.available}))
    }
    func testForeignCDNAndMultipleDurlRejected() {
        let foreign = ["dash":["video":[track("https://evil.example/video.m4s")],"audio":[track(codec:"mp4a.40.2")]]]
        XCTAssertFalse(Bilibili.playback(foreign).contains(where:{$0.available}))
        XCTAssertFalse(Bilibili.playback(["quality":80,"durl":[["url":"https://v.bilivideo.com/1.mp4"],["url":"https://v.bilivideo.com/2.mp4"]]]).contains(where:{$0.available}))
    }
    func testOneDurlPreservesOriginalURL() {
        let p = Bilibili.playback(["quality":80,"format":"mp4","durl":[["url":"https://v.bilivideo.com/input.mp4"]]])
        XCTAssertEqual(p.first?.video?.urls.first,"https://v.bilivideo.com/input.mp4")
    }
    func testFilenameAndWorkPersistence()throws {
        var w = try XCTUnwrap(Douyin.work(post())); w.title = "a/b:c\n../\\test"; w.author = "fixture"
        XCTAssertFalse(w.filename.contains("/")); XCTAssertFalse(w.filename.contains("\\")); XCTAssertFalse(w.filename.contains("\n"))
        XCTAssertEqual(try JSONDecoder().decode(Work.self,from:JSONEncoder().encode(w)),w)
    }
}
