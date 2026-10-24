import Foundation
import WebKit
import CryptoKit
import MemoCore

/// API redirects are never followed with account credentials.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor
final class PlatformClient {
    static let shared = PlatformClient()
    static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private let session: URLSession
    private var mixin = "", keyDate = Date.distantPast
    init() {
        let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 40
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; session = URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }
    func cookies(_ url: URL) async -> [HTTPCookie] {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return all.filter {
            let root = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
            let h = url.host?.lowercased() ?? ""
            let matches = $0.domain.hasPrefix(".") ? MediaURL.domain(h, root.lowercased()) : h == root.lowercased()
            let path = $0.path.isEmpty ? "/" : $0.path
            let urlPath = url.path.isEmpty ? "/" : url.path
            let pathMatch = urlPath == path || urlPath.hasPrefix(path.hasSuffix("/") ? path : path + "/")
            return matches && pathMatch && (!$0.isSecure || url.scheme == "https") && ($0.expiresDate == nil || $0.expiresDate! > Date())
        }
    }
    func cookieHeader(_ url: URL) async -> String { HTTPCookie.requestHeaderFields(with: await cookies(url))["Cookie"] ?? "" }
    func request(_ raw: String, platform: Platform, credentials: Bool = true, suppliedCookie: String = "") async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: raw), url.scheme == "https", platform.official(url.host ?? ""), url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { throw PlatformError("拒绝不支持的平台地址") }
        var r = URLRequest(url: url); r.setValue(Self.agent, forHTTPHeaderField: "User-Agent"); r.setValue(platform.home, forHTTPHeaderField: "Referer")
        if credentials {
            // Supplied manual Cookie only applies to the initial official origin.
            let value = suppliedCookie.isEmpty ? await cookieHeader(url) : suppliedCookie
            guard !value.contains("\r"), !value.contains("\n") else { throw MemoError.invalidHeader }
            if !value.isEmpty { r.setValue(value, forHTTPHeaderField: "Cookie") }
        }
        let (bytes, response) = try await session.data(for: r)
        guard bytes.count <= 8_000_000, let http = response as? HTTPURLResponse else { throw PlatformError("平台响应过大或无效") }
        if credentials {
            let fields = http.allHeaderFields.reduce(into: [String:String]()) { if let k = $1.key as? String, let v = $1.value as? String { $0[k] = v } }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
                let root = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                if platform.official(root), MediaURL.domain(url.host ?? "", root) { await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) }
            }
        }
        return (bytes, http)
    }
    func resolve(_ input: String, platform: Platform) async throws -> String {
        var current = platform == .bilibili ? try Bilibili.link(input) : try Link.extract(input)
        for _ in 0..<7 {
            try Task.checkCancellation()
            if platform == .bilibili, !Bilibili.videoID(current).isEmpty || !Bilibili.userID(current).isEmpty || !Bilibili.liveID(current).isEmpty { return current }
            if platform == .douyin, !MediaURL.secID(current).isEmpty { return current }
            let (_, response) = try await request(current, platform: platform, credentials: false)
            guard (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: response.url)?.absoluteURL else { return current }
            guard next.scheme == "https", platform.official(next.host ?? ""), next.user == nil, next.password == nil else { throw PlatformError("分享链接跳转到了不支持的地址") }
            current = next.absoluteString
        }
        throw PlatformError("分享链接跳转次数过多")
    }
    func bili(_ path: String) async throws -> [String: Any] {
        let raw = "https://api.bilibili.com" + path
        let (bytes,response) = try await request(raw, platform: .bilibili)
        guard response.statusCode == 200 else { throw PlatformError("Bilibili 请求失败（HTTP \(response.statusCode)），请打开官方网页完成验证") }
        return try Bilibili.data(bytes)
    }
    func signed(_ path: String, params: [String: String]) async throws -> String {
        if mixin.isEmpty || Date().timeIntervalSince(keyDate) > 30 {
            let (raw,response) = try await request("https://api.bilibili.com/x/web-interface/nav", platform: .bilibili)
            guard response.statusCode == 200, let root = try JSONSerialization.jsonObject(with: raw) as? [String:Any], let data = root["data"] as? [String:Any] else { throw PlatformError("平台未返回请求密钥，请打开官方网页后重试") }
            let images = data["wbi_img"] as? [String: String] ?? [:]
            let key = ["img_url", "sub_url"].compactMap { URL(string: images[$0] ?? "")?.deletingPathExtension().lastPathComponent }.joined()
            let indexes = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13]
            let chars = Array(key); guard chars.count >= 64 else { throw PlatformError("平台请求密钥格式变化，请登录后重试") }
            mixin = String(indexes.map { chars[$0] }); keyDate = Date()
        }
        var p = params; p["wts"] = String(Int(Date().timeIntervalSince1970))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let query = p.keys.sorted().map { k in encode(k) + "=" + encode(p[k]!.filter { !"!'()*".contains($0) }) }.joined(separator: "&")
        let hash = Insecure.MD5.hash(data: Data((query + mixin).utf8)).map { String(format: "%02x", $0) }.joined()
        return path + "?" + query + "&w_rid=" + hash
    }
    func parts(_ id: String) async throws -> [Work] {
        guard !MediaURL.match(#"^(BV[0-9A-Za-z]{10}|av[0-9]{1,20})$"#, id).isEmpty else { throw PlatformError("视频 ID 无效") }
        return Bilibili.parts(try await bili("/x/web-interface/view?" + (id.hasPrefix("BV") ? "bvid=" + id : "aid=" + id.dropFirst(2))))
    }
    func qualities(_ work: Work) async throws -> [BiliQuality] {
        let path = try await signed("/x/player/wbi/playurl", params: ["bvid":work.bvid,"cid":String(work.cid),"qn":"127","fnval":"4048","fourk":"1"])
        return Bilibili.playback(try await bili(path))
    }
    func userPage(_ mid: String, page: Int) async throws -> ([Work], Bool) {
        let path = try await signed("/x/space/wbi/arc/search", params: ["mid":mid,"pn":String(page),"ps":"30","order":"pubdate"])
        let data = try await bili(path), list = data["list"] as? [String: Any] ?? [:], pages = data["page"] as? [String: Any] ?? [:]
        guard let videos = list["vlist"] as? [[String: Any]], let count = pages["count"] as? Int else { throw PlatformError("平台未返回完整主页分页，请登录或验证后重试") }
        var result: [Work] = []
        for v in videos { try Task.checkCancellation(); if let id = v["bvid"] as? String { result += try await parts(id) } }
        let more = page * 30 < count
        if more && result.isEmpty { throw PlatformError("主页分页未推进，请稍后重试") }; return (result, more)
    }
    func live(_ original: Source) async throws -> (recording: Source, preview: Source?, result: LiveResult?) {
        let source = try original.validated(), platform = Link.platform(source.url)
        if platform == "媒体直链" { return (source, URL(string: source.url)?.pathExtension.lowercased() == "m3u8" ? source : nil, nil) }
        let p: Platform = platform == "抖音" ? .douyin : .bilibili
        let canonical = try await resolve(source.url, platform: p)
        let result: LiveResult
        if p == .douyin {
            let (body,response) = try await request(canonical, platform: p, suppliedCookie: source.cookie)
            guard response.statusCode == 200 else { throw PlatformError("分享页面不可用，请打开官方网页完成验证") }
            let id = Douyin.roomID(canonical).isEmpty ? Douyin.roomID(String(data: body, encoding: .utf8) ?? "") : Douyin.roomID(canonical)
            guard !id.isEmpty else { throw PlatformError("未识别直播间，请重新复制正在直播的房间分享链接") }
            let (bytes,_) = try await request("https://webcast.amemv.com/webcast/room/reflow/info/?room_id=\(id)&live_id=1&app_id=1128", platform: p)
            result = try Douyin.live(bytes, roomID: id)
        } else {
            let id = Bilibili.liveID(canonical); guard !id.isEmpty else { throw PlatformError("这是点播或主页链接，请在作品页打开；直播录制需要直播间链接") }
            func fetch(_ qn: Int) async throws -> ([String:Any],LiveResult) {
                let raw = "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo?room_id=\(id)&protocol=0,1&format=0,1,2&codec=0,1&qn=\(qn)&platform=web&ptype=8"
                let (bytes,response) = try await request(raw, platform:p)
                guard response.statusCode == 200 else { throw PlatformError("直播接口要求验证（HTTP \(response.statusCode)）") }
                let data = try Bilibili.data(bytes); return (data,try Bilibili.live(data))
            }
            let (data,first) = try await fetch(source.qualityId > 0 ? source.qualityId : 10000)
            var best = first
            if source.qualityId == 0 {
                let info = data["playurl_info"] as? [String:Any] ?? [:], play = info["playurl"] as? [String:Any] ?? [:]
                let advertised = (play["g_qn_desc"] as? [[String:Any]] ?? []).compactMap { $0["qn"] as? Int }.sorted(by:>)
                for qn in advertised.prefix(4) where qn > (best.best?.qualityID ?? 0) {
                    let (_,probe) = try await fetch(qn)
                    if (probe.best?.qualityID ?? 0) > (best.best?.qualityID ?? 0) { best = probe }
                    if probe.best?.qualityID == qn { break }
                }
            }
            result = best
        }
        let chosen: LiveStream?
        if source.qualityId > 0 { chosen = result.streams.first { $0.qualityID == source.qualityId } } else { chosen = result.best }
        guard let best = chosen else { throw PlatformError("当前会话未开放所选直播画质，请重新选择") }
        func mediaSource(_ stream: LiveStream) -> Source {
            var s = source; s.url = stream.url; s.cookie = ""; s.referer = p.home; s.agent = Self.agent
            return s
        }
        return (mediaSource(best), result.preview.map { mediaSource($0) }, result)
    }
}
