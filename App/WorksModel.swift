import Foundation
import WebKit
import SwiftUI
import MemoCore

@MainActor
final class WorksModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    let platform: Platform
    @Published private(set) var works: [Work] = []
    @Published var input = ""
    @Published var search = ""
    @Published var message = ""
    @Published var chosen = Set<String>()
    @Published var busy = false
    @Published var complete = false
    @Published var gathering = false
    @Published var showBrowser = false
    @Published var sessionLabel = "官方网页登录"
    private var canonical = "", secID = "", mid = "", page = 1, cursor = ""
    private var known = false, repeated = 0, foreground = true, generation = UUID()
    private var task: Task<Void,Never>?, ticker: Timer?
    private let file: URL
    private var writable = true
    lazy var web: WKWebView = makeWeb()
    struct Cache: Codable { var works: [Work]; var input: String }
    init(platform: Platform) {
        self.platform = platform
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Memo/works-\(platform.rawValue).json")
        super.init()
        if FileManager.default.fileExists(atPath: file.path) {
            do { let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: file)); works = cache.works; input = cache.input }
            catch { writable = false; message = "作品缓存无法读取，已保留原文件；本次可继续浏览，暂停覆盖缓存。" }
        }
    }
    var filtered: [Work] { let key = search.trimmingCharacters(in: .whitespacesAndNewlines); return key.isEmpty ? works : works.filter { $0.title.localizedCaseInsensitiveContains(key) || $0.author.localizedCaseInsensitiveContains(key) || $0.id.contains(key) } }
    private func save() {
        guard writable else { return }
        do { try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(Cache(works: works,input: input)).write(to: file, options: [.atomic,.completeFileProtectionUntilFirstUserAuthentication]) }
        catch { message = "作品列表暂未保存，请检查存储空间。" }
    }
    func open() {
        pause(); generation = UUID(); let token = generation; busy = true; complete = false; known = false; repeated = 0; cursor = ""; page = 1; message = "正在解析分享入口…"
        task = Task {
            defer { if generation == token { busy = false } }
            do {
                let link = try await PlatformClient.shared.resolve(input, platform: platform)
                guard generation == token else { return }
                canonical = link; works = []; chosen.removeAll()
                if platform == .douyin {
                    secID = MediaURL.secID(link); guard !secID.isEmpty else { throw PlatformError("请从抖音博主主页重新复制分享链接") }
                    web.load(URLRequest(url: URL(string: link)!)); showBrowser = true; gathering = true; startTicker()
                    message = "正在读取官方网页作品列表；如有验证，请在此网页完成。"
                } else {
                    mid = Bilibili.userID(link)
                    if !mid.isEmpty { try await nextBili(token: token) }
                    else { let id = Bilibili.videoID(link); guard !id.isEmpty else { throw PlatformError("这是直播间，请在直播页添加录制") }; works = try await PlatformClient.shared.parts(id); complete = true; message = "已展开 \(works.count) 个分 P"; save() }
                }
            } catch { if generation == token { message = DownloadManager.safeError(error); gathering = false } }
        }
    }
    func next() {
        guard !busy, !complete else { return }
        if platform == .douyin {
            guard !canonical.isEmpty else { open(); return }
            gathering = true; showBrowser = true; scroll(); startTicker(); return
        }
        guard !mid.isEmpty else { open(); return }
        busy = true; let token = generation
        task = Task { defer { busy = false }; do { try await nextBili(token: token) } catch { message = DownloadManager.safeError(error); gathering = false } }
    }
    private func nextBili(token: UUID) async throws {
        let (incoming,more) = try await PlatformClient.shared.userPage(mid,page: page)
        guard generation == token, !Task.isCancelled else { throw CancellationError() }
        merge(incoming); page += 1; complete = !more; save(); message = complete ? "已到平台返回的公开列表末尾" : "已获取 \(works.count) 个分 P，可继续下一页"
    }
    func all() {
        if gathering { pause(); return }
        if platform == .douyin { next(); return }
        guard !busy, !mid.isEmpty, !complete else { return }
        gathering = true; busy = true; let token = generation
        task = Task {
            defer { if generation == token { busy = false; gathering = false } }
            do { while gathering && !complete && foreground { try Task.checkCancellation(); try await nextBili(token: token); if !complete { try await Task.sleep(nanoseconds: 1_500_000_000) } } }
            catch { if generation == token { message = DownloadManager.safeError(error) } }
        }
    }
    func pause() { gathering = false; ticker?.invalidate(); ticker = nil; task?.cancel(); task = nil; busy = false }
    func clear() { pause(); generation = UUID(); works = []; chosen = []; complete = false; canonical = ""; secID = ""; mid = ""; input = ""; search = ""; web.stopLoading(); web.loadHTMLString("", baseURL: nil); message = ""; save() }
    func setForeground(_ value: Bool) { foreground = value; if !value { pause(); web.setAllMediaPlaybackSuspended(true) } else { web.setAllMediaPlaybackSuspended(false); Task { await refreshSession() } } }
    private func merge(_ incoming: [Work]) {
        for w in incoming {
            if let i = works.firstIndex(where: { $0.id == w.id }) { works[i] = w } else { works.append(w) }
        }
    }
    func login() { showBrowser = true; web.load(URLRequest(url: URL(string: platform == .bilibili ? "https://passport.bilibili.com/login" : platform.home)!)) }
    func refreshSession() async {
        if platform == .bilibili {
            do { let d = try await PlatformClient.shared.bili("/x/web-interface/nav"); sessionLabel = (d["isLogin"] as? Bool) == true ? "已登录 · \(d["uname"] as? String ?? "Bilibili")" : "官方网页登录" }
            catch { sessionLabel = "登录／验证 Bilibili" }
        } else {
            let cookies = await PlatformClient.shared.cookies(URL(string: platform.home)!)
            sessionLabel = cookies.contains { ["sessionid","sessionid_ss"].contains($0.name) && !$0.value.isEmpty } ? "检测到抖音登录会话" : "官方网页登录"
        }
    }
    func logout() async {
        pause(); web.stopLoading(); web.loadHTMLString("", baseURL: nil)
        let store = WKWebsiteDataStore.default()
        for cookie in await store.httpCookieStore.allCookies() {
            let root = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if platform.official(root) { await store.httpCookieStore.deleteCookie(cookie) }
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records.filter { platform.official($0.displayName) })
        sessionLabel = "官方网页登录"; message = "已退出本机 \(platform.label) 会话"
    }
    private func makeWeb() -> WKWebView {
        let c = WKWebViewConfiguration(); c.websiteDataStore = .default(); c.mediaTypesRequiringUserActionForPlayback = .all; c.allowsInlineMediaPlayback = true
        c.userContentController.add(WeakMessage(self), name: "memoPosts")
        if platform == .douyin, let path = Bundle.main.url(forResource: "works-observe", withExtension: "js"), let script = try? String(contentsOf: path, encoding: .utf8) {
            c.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let view = WKWebView(frame: .zero, configuration: c); view.customUserAgent = PlatformClient.agent; view.navigationDelegate = self; view.allowsBackForwardNavigationGestures = true
        return view
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard url.scheme == "https", url.user == nil, url.password == nil else { decisionHandler(.cancel); return }
        decisionHandler(navigationAction.targetFrame?.isMainFrame == true && !platform.official(url.host ?? "") ? .cancel : .allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await refreshSession() }
        guard platform == .douyin, !secID.isEmpty, MediaURL.secID(webView.url?.absoluteString ?? "") == secID else { return }
        let token = generation
        webView.evaluateJavaScript("(function(){try{var d=window._ROUTER_DATA;var e=document.getElementById('RENDER_DATA');if(!d&&e)d=JSON.parse(decodeURIComponent(e.textContent));return JSON.stringify(d||{});}catch(e){return '{}';}})()") { [weak self] result,_ in
            guard let self, self.generation == token, let body = result as? String, body.utf8.count < 8_000_000, let p = try? Douyin.embedded(Data(body.utf8), expected: self.secID) else { return }
            self.merge(p.works); self.save()
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard platform == .douyin, message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "https", platform.official(message.frameInfo.securityOrigin.host), !secID.isEmpty,
              let entry = message.body as? [String:String], let raw = entry["url"], let u = URL(string: raw), u.scheme == "https", platform.official(u.host ?? ""), ["/aweme/v1/web/aweme/post/","/aweme/v1/web/aweme/post"].contains(u.path), MediaURL.query(raw,"sec_user_id") == secID,
              let body = entry["body"], body.utf8.count <= 8_000_000 else { return }
        do {
            let p = try Douyin.page(Data(body.utf8), expected: secID), before = works.count
            merge(p.works); known = p.known
            repeated = p.hasMore && p.cursor == cursor && works.count == before ? repeated + 1 : 0; cursor = p.cursor
            complete = p.known && !p.hasMore
            if complete || repeated >= 3 { gathering = false; ticker?.invalidate(); ticker = nil }
            self.message = complete ? "已到平台返回的作品列表末尾" : repeated >= 3 ? "平台分页未推进，请完成验证后重试" : "已获取 \(works.count) 项，自动去重"
            save()
        } catch { self.message = DownloadManager.safeError(error); pause() }
    }
    private func startTicker() {
        ticker?.invalidate(); guard foreground else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in guard let self, self.gathering, self.foreground else { return }; self.scroll() } }
    }
    private func scroll() {
        guard let url = web.url, platform == .douyin, MediaURL.secID(url.absoluteString) == secID else { return }
        web.evaluateJavaScript("(function(){var roots=[document.scrollingElement].concat(Array.from(document.querySelectorAll('div')).filter(function(e){var s=getComputedStyle(e);return e.clientHeight>150&&e.scrollHeight>e.clientHeight+100&&(s.overflowY==='auto'||s.overflowY==='scroll');}).slice(0,10));roots.forEach(function(e){if(e){e.scrollTop=e.scrollHeight;e.dispatchEvent(new Event('scroll',{bubbles:true}));}});window.dispatchEvent(new Event('scroll'));return true;})()", completionHandler: nil)
    }
}
private final class WeakMessage: NSObject, WKScriptMessageHandler {
    weak var owner: WorksModel?
    init(_ owner: WorksModel) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.userContentController(userContentController, didReceive: message) }
}
struct OfficialWebView: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
struct OfficialBrowser: View {
    @ObservedObject var model: WorksModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack { Image(systemName: "lock.fill"); Text(model.web.url?.host ?? model.platform.label).lineLimit(1); Spacer(); if model.gathering { ProgressView() } }.font(.caption).padding(12)
                OfficialWebView(web: model.web)
            }
            .navigationTitle(model.platform.label + " 官方网页").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回 Memo") { dismiss(); Task { await model.refreshSession() } } }
                ToolbarItem(placement: .topBarTrailing) { Button("刷新", systemImage: "arrow.clockwise") { model.web.reload() } }
            }
        }
    }
}
