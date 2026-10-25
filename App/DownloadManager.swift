import Foundation
import UIKit
import MemoCore

struct DownloadJob: Codable, Identifiable {
    let id: String
    var work: Work
    var state = "排队中"
    var error = ""
    var received: Int64 = 0, expected: Int64 = 0
    var files: [String] = []
    var next = 0
    var backup = 0
    var wanted = true
    var token = UUID().uuidString
    var complete: Bool { state == "已完成" }
    init(work: Work) { self.id = work.key; self.work = work }
}
final class MemoAppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundCompletion: (() -> Void)?
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Self.backgroundCompletion = completionHandler
        Task { @MainActor in DownloadManager.shared.reconnect() }
    }
}
@MainActor
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    @Published private(set) var jobs: [DownloadJob] = []
    @Published var message: String?
    @Published var version = 0
    let directory: URL
    private let staging: URL, stateFile: URL
    private var session: URLSession!
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var preparing = Set<String>(), joining: [String: NativeCapture] = [:]
    private var foreground = true, restoring = true, writable = true
    override init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = root.appendingPathComponent("Works", isDirectory: true)
        staging = root.appendingPathComponent(".MemoTransfers", isDirectory: true)
        stateFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Memo/downloads.json")
        super.init()
        do {
            for d in [directory,staging,stateFile.deletingLastPathComponent()] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication]) }
            if FileManager.default.fileExists(atPath: stateFile.path) { jobs = try JSONDecoder().decode([DownloadJob].self, from: Data(contentsOf: stateFile))
                guard jobs.allSatisfy({ Self.safeID($0.id) && $0.files.allSatisfy { !$0.contains("/") && !$0.contains("\\") && !$0.hasPrefix(".") } }) else { throw CocoaError(.fileReadCorruptFile) } }
        } catch { writable = false; message = "下载队列无法读取或保存，原数据已保留。请先备份应用数据。" }
        let c = URLSessionConfiguration.background(withIdentifier: "app.memo.ios.transfers.v1")
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.isDiscretionary = false; c.sessionSendsLaunchEvents = true
        c.httpMaximumConnectionsPerHost = 2; c.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
        reconnect()
    }
    func reconnect() {
        guard session != nil else { return }
        session.getAllTasks { [weak self] pending in
            Task { @MainActor in
                guard let self else { return }
                for task in pending {
                    guard let d = task as? URLSessionDownloadTask, let token = d.taskDescription,
                          let j = self.jobs.first(where: { $0.token == token && $0.wanted }) else { task.cancel(); continue }
                    if self.tasks[j.id] == nil { self.tasks[j.id] = d } else if self.tasks[j.id]?.taskIdentifier != d.taskIdentifier { d.cancel() }
                }
                self.restoring = false; self.pump()
            }
        }
    }
    private func persist() -> Bool {
        guard writable else { return false }
        do { try JSONEncoder().encode(jobs).write(to: stateFile, options: [.atomic,.completeFileProtectionUntilFirstUserAuthentication]); return true }
        catch { message = "下载队列保存失败，请检查剩余空间。"; return false }
    }
    func enqueue(_ works: [Work]) {
        guard writable else { return }
        for work in works {
            guard Self.safeID(work.key), work.platform == .bilibili || work.downloadable else { continue }
            if let index = jobs.firstIndex(where: { $0.id == work.key }) {
                guard !jobs[index].complete, !jobs[index].wanted else { continue }
                if jobs[index].next == 0 { jobs[index].work = work }; jobs[index].wanted = true; jobs[index].backup = 0; jobs[index].state = "排队中"; jobs[index].error = ""
            } else { jobs.append(DownloadJob(work: work)) }
        }
        guard persist() else { return }; pump()
    }
    func retry(_ id: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].complete, tasks[id] == nil, !preparing.contains(id), joining[id] == nil else { return }
        jobs[i].wanted = true; jobs[i].backup = 0; jobs[i].state = "排队中"; jobs[i].error = ""; jobs[i].token = UUID().uuidString
        guard persist() else { return }; pump()
    }
    func cancel(_ id: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].complete else { return }
        jobs[i].wanted = false; jobs[i].state = "已暂停"; jobs[i].token = UUID().uuidString
        tasks.removeValue(forKey: id)?.cancel(); joining[id]?.cancel(); _ = persist(); pump()
    }
    func removeFinished() { jobs.removeAll { !$0.wanted && joining[$0.id] == nil && !preparing.contains($0.id) }; _ = persist() }
    func setForeground(_ value: Bool) { foreground = value; if value { pump() } else { for handle in joining.values { handle.cancel() } } }
    private func pump() {
        guard !restoring, writable, foreground else { return }
        // One job at a time, with independent OS-managed file transfers.
        guard tasks.isEmpty, preparing.isEmpty, joining.isEmpty, let job = jobs.first(where: { $0.wanted }) else { return }
        preparing.insert(job.id)
        Task {
            do {
                var work = job.work
                if work.platform == .bilibili {
                    let qualities = try await PlatformClient.shared.qualities(work)
                    let chosen = work.qualityID > 0 ? qualities.first { $0.id == work.qualityID && $0.available } : qualities.first { $0.available }
                    guard let chosen else { throw PlatformError("所选画质当前会话未开放，请登录或重新选择画质；不会自动降档") }
                    work = try Bilibili.select(work, quality: chosen)
                }
                guard let i = jobs.firstIndex(where: { $0.token == job.token && $0.wanted }) else { preparing.remove(job.id); pump(); return }
                // Queue identity is stable even when automatic quality resolves later.
                jobs[i].work.media = work.media; jobs[i].work.audio = work.audio; jobs[i].work.qualityLabel = work.qualityLabel; jobs[i].work.qualityID = work.qualityID
                jobs[i].state = "下载中"; preparing.remove(job.id)
                try startNext(index: i)
            } catch { preparing.remove(job.id); fail(token: job.token, message: Self.safeError(error)) }
        }
    }
    private func resources(_ work: Work) -> [Media] { work.album ? work.images : [work.media,work.audio].compactMap { $0 } }
    private func startNext(index i: Int) throws {
        let job = jobs[i], media = resources(job.work)
        guard !media.isEmpty, media.allSatisfy({ !$0.urls.isEmpty }) else { throw PlatformError("没有完整可保存的原文件源") }
        // Validate previously completed pages before resuming an interrupted album.
        while jobs[i].next > 0 && (jobs[i].files.count < jobs[i].next || !FileManager.default.fileExists(atPath: staging.appendingPathComponent(jobs[i].files[jobs[i].next-1]).path)) {
            jobs[i].next -= 1
            jobs[i].files = Array(jobs[i].files.prefix(jobs[i].next))
        }
        if jobs[i].next >= media.count { finalize(i); return }
        let n = jobs[i].next
        let urls = media[n].urls
        let raw = jobs[i].backup < urls.count ? urls[jobs[i].backup] : ""
        guard MediaURL.original(raw, platform: job.work.platform), let url = URL(string: raw) else { throw PlatformError("媒体地址不属于此平台允许的 HTTPS 媒体域") }
        var request = URLRequest(url: url); request.setValue(PlatformClient.agent, forHTTPHeaderField: "User-Agent"); request.setValue(job.work.platform.home, forHTTPHeaderField: "Referer")
        jobs[i].received = 0; jobs[i].expected = 0; jobs[i].state = job.work.album ? "下载图集 \(n+1)/\(media.count)" : (n == 1 ? "下载音轨" : "下载视频")
        guard persist() else { throw PlatformError("队列保存失败，已暂停") }
        let task = session.downloadTask(with: request); task.taskDescription = job.token; tasks[job.id] = task; task.resume()
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let token = downloadTask.taskDescription else { return }
        Task { @MainActor in
            guard let i = self.jobs.firstIndex(where: { $0.token == token && $0.wanted }) else { return }
            self.jobs[i].received = totalBytesWritten; self.jobs[i].expected = totalBytesExpectedToWrite
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let token = downloadTask.taskDescription else { return }
        // The delegate's temporary file disappears after this method returns.
        let pending = FileManager.default.temporaryDirectory.appendingPathComponent("Memo-" + UUID().uuidString)
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else { throw PlatformError("下载响应失败，请刷新作品或稍后重试") }
            guard let raw = response.url?.absoluteString, MediaURL.allowed(raw, platform: .douyin) || MediaURL.allowed(raw, platform: .bilibili) else { throw PlatformError("媒体跳转到了不支持的地址") }
            let length = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard length > 0, response.expectedContentLength < 0 || Int64(length) == response.expectedContentLength else { throw PlatformError("媒体下载不完整，已保留之前完成的内容") }
            try FileManager.default.moveItem(at: location, to: pending)
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath:pending.path)
            Task { @MainActor in self.accept(token: token, pending: pending, response: response) }
        } catch { Task { @MainActor in self.fail(token: token, message: Self.safeError(error)) } }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let token = task.taskDescription else { return }
        Task { @MainActor in self.fail(token: token, message: Self.safeError(error)) }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in let completion = MemoAppDelegate.backgroundCompletion; MemoAppDelegate.backgroundCompletion = nil; completion?() }
    }
    private func accept(token: String, pending: URL, response: HTTPURLResponse) {
        defer { try? FileManager.default.removeItem(at: pending) }
        guard let i = jobs.firstIndex(where: { $0.token == token && $0.wanted }) else { return }
        tasks.removeValue(forKey: jobs[i].id)
        do {
            guard MediaURL.original(response.url?.absoluteString ?? "", platform: jobs[i].work.platform) else { throw PlatformError("媒体响应不属于当前平台") }
            let header = try FileHandle(forReadingFrom: pending); let bytes = Array(try header.read(upToCount: 32) ?? Data()); try header.close()
            let ext: String
            if jobs[i].work.album {
                guard let original = MediaMagic.imageExtension(bytes) else { throw PlatformError("平台未返回原图文件，之前完成的图片已保留") }
                ext = original
            } else {
                guard bytes.count >= 8, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" || Array(bytes.prefix(4)) == [0x1a,0x45,0xdf,0xa3] else { throw PlatformError("平台未返回可用的媒体文件，请刷新作品") }
                ext = "mp4"
            }
            let name = UUID().uuidString + "." + ext, target = staging.appendingPathComponent(name)
            try FileManager.default.moveItem(at: pending, to: target)
            jobs[i].files.append(name); jobs[i].next += 1; jobs[i].backup = 0
            guard persist() else { throw PlatformError("下载状态保存失败，已暂停") }
            try startNext(index: i)
        } catch { fail(token: token, message: Self.safeError(error)) }
    }
    private func finalize(_ i: Int) {
        let job = jobs[i]
        let files = job.files.map { staging.appendingPathComponent($0) }
        guard !files.isEmpty else { fail(token: job.token, message: "没有完整文件"); return }
        let folder = directory.appendingPathComponent(job.id, isDirectory: true)
        if !foreground, files.count == 2, !job.work.album { jobs[i].state = "等待返回应用合成"; _ = persist(); return }
        preparing.insert(job.id)
        Task {
            let temporary = staging.appendingPathComponent(UUID().uuidString + ".mp4")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if job.work.album {
                    for (n,file) in files.enumerated() {
                        let dest = folder.appendingPathComponent(String(format: "%03d", n+1) + "." + file.pathExtension)
                        if !FileManager.default.fileExists(atPath: dest.path) {
                            let copy = staging.appendingPathComponent(UUID().uuidString + ".part")
                            do { try FileManager.default.copyItem(at: file, to: copy); try FileManager.default.moveItem(at: copy, to: dest) } catch { try? FileManager.default.removeItem(at: copy); throw error }
                        }
                    }
                } else {
                    let target = folder.appendingPathComponent(job.work.filename)
                    if !FileManager.default.fileExists(atPath: target.path) {
                        if files.count == 2 {
                            let handle = try NativeCapture(); joining[job.id] = handle; jobs[i].state = "无转码合成…"
                            let result = await Task.detached(priority: .utility) { handle.join(video: files[0], audio: files[1], output: temporary) }.value
                            guard result >= 0 else { throw PlatformError("音视频合成未完成，原音视频已保留，可重试") }
                            guard jobs.contains(where: { $0.token == job.token && $0.wanted }) else { throw CancellationError() }
                            try FileManager.default.moveItem(at: temporary, to: target)
                        } else {
                            try FileManager.default.copyItem(at: files[0], to: temporary)
                            try FileManager.default.moveItem(at: temporary, to: target)
                        }
                    }
                }
                guard let n = jobs.firstIndex(where: { $0.token == job.token && $0.wanted }) else { throw CancellationError() }
                jobs[n].state = "已完成"; jobs[n].wanted = false; jobs[n].error = ""
                // Retain source files unless completion metadata is durable.
                if persist() { for file in files { try? FileManager.default.removeItem(at: file) } }
                version += 1
            } catch { fail(token: job.token, message: Self.safeError(error)) }
            try? FileManager.default.removeItem(at: temporary)
            joining.removeValue(forKey: job.id); preparing.remove(job.id); pump()
        }
    }
    private func fail(token: String, message: String) {
        guard let i = jobs.firstIndex(where: { $0.token == token && $0.wanted }) else { return }
        let id = jobs[i].id
        tasks.removeValue(forKey: id)?.cancel()
        let resources = resources(jobs[i].work)
        if jobs[i].next < resources.count, jobs[i].backup + 1 < resources[jobs[i].next].urls.count, !preparing.contains(id), joining[id] == nil {
            jobs[i].backup += 1; jobs[i].token = UUID().uuidString
            do { try startNext(index:i); return } catch { /* All permitted backup URLs exhausted. */ }
        }
        jobs[i].wanted = false; jobs[i].state = "下载未完成"; jobs[i].error = message
        _ = persist(); pump()
    }
    func files() -> [URL] {
        guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.path > $1.path }
    }
    func delete(_ file: URL) {
        guard file.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else { return }
        do { try FileManager.default.removeItem(at: file); version += 1 }
        catch { message = "文件删除失败" }
    }
    nonisolated static func safeID(_ id: String) -> Bool { !MediaURL.match(#"^([0-9]{10,24}|bili_BV[0-9A-Za-z]{10}_[0-9]{1,20})(?:_q[0-9]{1,6})?$"#, id).isEmpty }
    nonisolated static func safeError(_ error: Error) -> String {
        if let e = error as? PlatformError { return e.message }
        if error is CancellationError { return "任务已暂停，已完成部分保留" }
        let e = error as NSError
        if e.domain == NSURLErrorDomain { return "网络请求未完成（\(e.code)），可稍后重试" }
        return "本地文件处理未完成（\(e.code)），请检查空间后重试"
    }
}
