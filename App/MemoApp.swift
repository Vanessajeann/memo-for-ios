import SwiftUI
import MemoCore
import AVKit
import UniformTypeIdentifiers

@main
struct MemoApp: App {
    @StateObject private var store = SourceStore()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store) }
    }
}

@MainActor
final class SourceStore: ObservableObject {
    @Published private(set) var sources: [Source] = []
    @Published var message: String?
    private var writable = true
    private let file: URL
    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Memo", isDirectory: true).appendingPathComponent("sources.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let backup = try SourceBackup.decode(Data(contentsOf: file))
            var checked: [Source] = []
            for s in backup.sources { checked = try SourceList.upsert(s, into: checked) }
            sources = checked
        } catch {
            writable = false
            message = "直播源文件无法读取，已保留原文件并暂停写入。请先备份应用数据。"
        }
    }
    private func persist(_ new: [Source]) throws {
        guard writable else { throw MemoError.invalidBackup }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(SourceBackup(sources: new)).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        sources = new
    }
    func save(_ s: Source) throws { try persist(SourceList.upsert(s, into: sources)) }
    func remove(_ s: Source) {
        do { try persist(sources.filter { $0.id != s.id }) }
        catch { message = error.localizedDescription }
    }
    func importBackup(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let backup = try SourceBackup.decode(handle.read(upToCount: 1_000_001) ?? Data())
            var updated = sources
            var imported = 0
            for var s in backup.sources {
                s.id = UUID().uuidString
                let checked = try s.validated()
                if updated.contains(where: { $0.url == checked.url }) { continue }
                updated = try SourceList.upsert(checked, into: updated); imported += 1
            }
            try persist(updated)
            message = "已导入 \(imported) 个直播源，重复项已跳过。"
        } catch { message = "导入未完成，原列表未修改：\(error.localizedDescription)" }
    }
    func exportData() throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(SourceBackup(sources: sources))
    }
}

struct RootView: View {
    @EnvironmentObject var store: SourceStore
    var body: some View {
        TabView {
            LiveView().tabItem { Label("直播", systemImage: "dot.radiowaves.left.and.right") }
            MigrationStatusView().tabItem { Label("移植进度", systemImage: "checklist") }
        }
        .alert("Memo", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("知道了") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
}

struct LiveView: View {
    @EnvironmentObject var store: SourceStore
    @State private var editor: Source?
    @State private var preview: Source?
    @State private var deleting: Source?
    @State private var importing = false
    @State private var exporting = false
    @State private var exportWarning = false
    @State private var document = SourceDocument()
    @State private var grid = true
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("开发验证版 · 录制与作品功能正在移植", systemImage: "hammer")
                        .font(.footnote).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: grid ? 3 : 1), spacing: 12) {
                        ForEach(store.sources) { source in
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.tint)
                                Text(source.name).font(.headline).lineLimit(2)
                                Text(Link.platform(source.url)).font(.caption2).foregroundStyle(.secondary)
                                Button("预览") { openPreview(source) }.buttonStyle(.bordered)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                            .padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                            .contextMenu {
                                Button("编辑", systemImage: "pencil") { editor = source }
                                Button("移除", systemImage: "trash", role: .destructive) { deleting = source }
                            }
                        }
                        if store.sources.count < 9 {
                            Button { editor = Source() } label: {
                                Label("添加", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 140)
                            }.buttonStyle(.bordered)
                        }
                    }
                    Text("支持保存 Android Memo 的直播源备份。当前预览仅用于无自定义请求头的 HLS 直链验证；平台分享解析与多路录制尚未接入。").font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Memo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(grid ? "切换列表" : "切换九宫格") { grid.toggle() }
                        Button("导入直播源") { importing = true }
                        Button("导出直播源") { exportWarning = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(item: $editor) { SourceEditor(source: $0) }
            .sheet(item: $preview) { StreamPreview(source: $0) }
            .confirmationDialog("移除直播源？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("移除", role: .destructive) { if let source = deleting { store.remove(source) }; deleting = nil }
            }
            .alert("备份包含请求头与 Cookie", isPresented: $exportWarning) {
                Button("取消", role: .cancel) {}
                Button("导出") {
                    do { document = SourceDocument(data: try store.exportData()); exporting = true }
                    catch { store.message = error.localizedDescription }
                }
            } message: { Text("请将备份保存在你信任的位置。") }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
                switch result { case .success(let url): store.importBackup(url); case .failure(let error): store.message = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Memo-直播源") { result in
                if case .failure(let error) = result { store.message = error.localizedDescription }
            }
        }
    }
    private func openPreview(_ source: Source) {
        guard Link.platform(source.url) == "媒体直链",
              URL(string: source.url)?.pathExtension.lowercased() == "m3u8",
              source.cookie.isEmpty, source.referer.isEmpty, source.agent == "Mozilla/5.0" else {
            store.message = "此开发版暂仅验证无自定义请求头的 HLS 直链。此源已保留，完整解析与录制仍在移植。"; return
        }
        preview = source
    }
}

struct SourceEditor: View {
    @EnvironmentObject var store: SourceStore
    @Environment(\.dismiss) private var dismiss
    @State var source: Source
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $source.name)
                TextField("直播分享文案或媒体直链", text: $source.url, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Section("请求头（可选）") {
                    TextField("Referer", text: $source.referer).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Cookie", text: $source.cookie).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("User-Agent", text: $source.agent).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("直播源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try store.save(source); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}

struct StreamPreview: View {
    let source: Source
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var audioError: String?
    var body: some View {
        NavigationStack {
            VStack {
                VideoPlayer(player: player)
                Text("预览不会保存录像。后台持续性仍需真机验证。").font(.footnote).padding()
                if let audioError { Text(audioError).font(.footnote) }
            }
            .navigationTitle(source.name)
            .toolbar { Button("关闭") { dismiss() } }
            .onAppear {
                do {
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                    try AVAudioSession.sharedInstance().setActive(true)
                    if let url = URL(string: source.url) { player = AVPlayer(url: url); player?.play() }
                } catch { audioError = "音频会话未能启动：\(error.localizedDescription)" }
            }
            .onDisappear {
                player?.pause(); player = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}

struct MigrationStatusView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("已接入，待真机验证") {
                    Text("直播源管理与 Android 备份兼容")
                    Text("HLS 直链预览与真实音频会话")
                }
                Section("待移植") {
                    Text("FFmpeg 多协议、多路录制、重连与文件整理")
                    Text("抖音／Bilibili 分享解析与会话")
                    Text("抖音视频、图集、主页分页下载")
                    Text("Bilibili 分 P、画质、音轨与 DASH 合成")
                    Text("下载队列、录像管理与系统导出")
                    Text("锁屏与切 App 的长期录制测试")
                }
                Section {
                    Text("以 Android 3.2.0-beta1 的全部功能为目标。当前包用于构建与界面验证，不是完整录制工具。")
                    Text("目标：iPhone 16 Pro Max / iOS 18.6.2。签名不会解除系统后台限制。")
                }
            }.navigationTitle("移植进度")
        }
    }
}

struct SourceDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data()
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
