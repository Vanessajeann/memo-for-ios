import SwiftUI
import MemoCore

struct WorksView:View {
    @ObservedObject var douyin:WorksModel
    @ObservedObject var bili:WorksModel
    @AppStorage("works.platform") private var platform = Platform.douyin.rawValue
    @State private var queue = false
    var body:some View {
        NavigationStack {
            VStack(spacing:0) {
                Picker("平台",selection:$platform) { Text("抖音").tag(Platform.douyin.rawValue); Text("Bilibili").tag(Platform.bilibili.rawValue) }.pickerStyle(.segmented).padding(.horizontal,18).padding(.bottom,10)
                WorksPane(model:platform == Platform.bilibili.rawValue ? bili : douyin)
            }
            .navigationTitle("作品").memoPage()
            .toolbar { Button("下载队列",systemImage:"arrow.down.circle") { queue = true } }
            .sheet(isPresented:$queue) { DownloadQueueView() }
        }
    }
}
struct WorksPane:View {
    @ObservedObject var model:WorksModel
    @EnvironmentObject var downloads:DownloadManager
    @AppStorage("works.grid") private var grid = true
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var qualities:Work?
    @State private var clear = false
    @State private var previewID:String?
    @State private var playing:LocalRecording?
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                VStack(spacing:12) {
                    HStack(alignment:.top,spacing:10) {
                        Image(systemName:model.platform == .douyin ? "person.crop.rectangle" : "play.rectangle.on.rectangle").foregroundStyle(MemoStyle.blue).padding(.top,5)
                        TextField(model.platform == .douyin ? "粘贴博主主页分享链接" : "粘贴 BV／AV、分享链接或 UP 主页",text:$model.input,axis:.vertical).font(.subheadline).lineLimit(1...3).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("粘贴",systemImage:"doc.on.clipboard") { if let value = UIPasteboard.general.string { model.input = value } }.labelStyle(.iconOnly).frame(width:36,height:36)
                    }
                    HStack {
                        Button("获取作品",systemImage:"arrow.down.doc") { model.open() }.buttonStyle(.borderedProminent).disabled(model.input.isEmpty)
                        Button(model.sessionLabel,systemImage:"person.crop.circle") { model.login() }.font(.caption).lineLimit(1)
                        Spacer(minLength:0)
                    }
                }.padding(16).glassCard()
                HStack {
                    Label("已获取 \(model.works.count)",systemImage:"square.stack").font(.caption)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("下一页") { model.next() }.disabled(model.busy || model.complete)
                    Button(model.gathering ? "暂停" : "获取全部") { model.all() }.disabled(model.complete)
                }.font(.caption)
                if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                HStack {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索作品、作者或 ID",text:$model.search).font(.subheadline)
                    if !model.search.isEmpty { Button("清除搜索",systemImage:"xmark.circle.fill") { model.search = "" }.labelStyle(.iconOnly).foregroundStyle(.secondary) }
                }.padding(12).glassCard(radius:16)
                HStack {
                    Button(model.filtered.allSatisfy { model.chosen.contains($0.id) } && !model.filtered.isEmpty ? "取消全选" : "全选") {
                        let ids = Set(model.filtered.filter { $0.platform == .bilibili || $0.downloadable }.map(\.id))
                        if ids.isSubset(of:model.chosen) { model.chosen.subtract(ids) } else { model.chosen.formUnion(ids) }
                    }
                    Text("已选 \(model.chosen.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button("切换布局",systemImage:grid ? "list.bullet" : "square.grid.3x3") { grid.toggle() }.labelStyle(.iconOnly).frame(width:36,height:36)
                    Button("清空",role:.destructive) { clear = true }.disabled(model.works.isEmpty)
                }.font(.caption)
                if model.filtered.isEmpty {
                    ContentUnavailableView(model.works.isEmpty ? "把喜欢的作品留在本机" : "没有匹配的作品",systemImage:"square.stack.3d.up",description:Text(model.platform == .douyin ? "从博主主页获取视频与图集，保留平台可用的原文件。" : "视频与分 P 单独列出，画质以当前登录会话实际返回为准。"))
                        .frame(minHeight:200)
                } else {
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:10),count:grid && !typeSize.isAccessibilitySize ? 3 : 1),spacing:12) {
                        ForEach(model.filtered) { work in
                            WorkCard(work:work,grid:grid && !typeSize.isAccessibilitySize,selected:model.chosen.contains(work.id),toggle:{ if !model.chosen.insert(work.id).inserted { model.chosen.remove(work.id) } },download:{ if work.platform == .bilibili { qualities = work } else { downloads.enqueue([work]) } },preview:{ preview(work) })
                        }
                    }
                }
            }.padding(.horizontal,18).padding(.top,8).padding(.bottom,16)
        }
        .safeAreaInset(edge:.bottom) {
            if !model.chosen.isEmpty {
                Button {
                    downloads.enqueue(model.works.filter { model.chosen.contains($0.id) }); model.message = "已加入下载队列。Bilibili 批量下载采用当前会话最高实际可用画质。"
                } label:{ Label("下载已选 \(model.chosen.count) 项",systemImage:"arrow.down.to.line").font(.subheadline.weight(.semibold)).frame(maxWidth:.infinity).padding(13) }
                    .buttonStyle(.borderedProminent).padding(.horizontal,18).padding(.bottom,4)
            }
        }
        .sheet(isPresented:$model.showBrowser) { OfficialBrowser(model:model) }
        .sheet(item:$qualities) { QualityPicker(work:$0) }
        .fullScreenCover(item:$playing) { LocalRecordingPlayer(recording:$0) }
        .confirmationDialog("清空此平台作品列表？已下载文件和队列会保留。",isPresented:$clear) { Button("清空列表",role:.destructive) { model.clear() } }
        .onChange(of:downloads.version) { _,_ in
            guard let id = previewID, let job = downloads.jobs.first(where:{ $0.id == id && $0.complete }), !job.work.album,
                  let file = downloads.files().first(where:{ $0.deletingLastPathComponent().lastPathComponent == id }) else { return }
            previewID = nil; playing = LocalRecording(url:file)
        }
    }
    private func preview(_ work:Work) {
        if let job = downloads.jobs.first(where:{ $0.id == work.key && $0.complete }), !job.work.album,
           let file = downloads.files().first(where:{ $0.deletingLastPathComponent().lastPathComponent == job.id }) { playing = LocalRecording(url:file); return }
        downloads.enqueue([work]); previewID = work.key; model.message = work.album ? "图集已加入队列，完成后可在录像页逐张预览。" : "正在缓存原文件，完成后自动播放；文件也会保留在录像页。"
    }
}
struct WorkCard:View {
    let work:Work, grid:Bool, selected:Bool
    let toggle:()->Void, download:()->Void, preview:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(alignment:.top,spacing:10) {
                cover.frame(width:grid ? nil : 68,height:grid ? 130 : 90).clipShape(RoundedRectangle(cornerRadius:13)).overlay(alignment:.topTrailing) {
                    if grid { selectButton.padding(3) }
                }
                if !grid { labels; Spacer(minLength:0); selectButton }
            }
            if grid { labels }
            HStack(spacing:6) {
                Button("预览",action:preview).frame(maxWidth:.infinity)
                Button(work.platform == .bilibili ? "画质" : "下载",action:download).frame(maxWidth:.infinity)
            }.font(.system(size:11,weight:.medium)).buttonStyle(.bordered).controlSize(.small)
        }.padding(grid ? 7 : 12).glassCard(radius:20)
    }
    private var labels:some View {
        VStack(alignment:.leading,spacing:4) {
            Text(work.title.isEmpty ? work.id : work.title).font(grid ? .system(size:11,weight:.medium) : .subheadline.weight(.medium)).lineLimit(2).frame(maxWidth:.infinity,minHeight:grid ? 30 : 36,alignment:.topLeading)
            Text(work.author).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1)
            Text(work.album ? "图集 · \(work.images.count) 张" : work.platform == .bilibili ? "分 P · 当前会话画质" : work.media?.quality ?? "暂无原文件源").font(.system(size:9)).foregroundStyle(.secondary).lineLimit(2).frame(minHeight:22,alignment:.top)
        }
    }
    private var selectButton:some View {
        Button(action:toggle) { Image(systemName:selected ? "checkmark.circle.fill" : "circle").font(.system(size:21)).symbolRenderingMode(.palette).foregroundStyle(selected ? MemoStyle.blue : Color.white,Color.black.opacity(0.35)).frame(width:36,height:36) }.buttonStyle(.plain).accessibilityLabel("选择 \(work.title)").disabled(work.platform != .bilibili && !work.downloadable)
    }
    private var cover:some View {
        ZStack {
            MemoStyle.blue.opacity(0.10)
            Image(systemName:work.album ? "photo.stack" : "play.rectangle").font(.title2).foregroundStyle(MemoStyle.blue.opacity(0.4))
            if MediaURL.allowed(work.cover,platform:work.platform), let url = URL(string:work.cover) {
                AsyncImage(url:url) { image in image.resizable().scaledToFill() } placeholder:{ Color.clear }
            }
        }.clipped()
    }
}
struct QualityPicker:View {
    let work:Work
    @EnvironmentObject var downloads:DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var choices:[BiliQuality] = []
    @State private var error = ""
    @State private var loading = true
    var body:some View {
        NavigationStack {
            List {
                Section { Text(work.title).font(.subheadline); Text("仅保存当前会话实际返回的完整媒体。平台未开放的画质会显示原因。").font(.caption).foregroundStyle(.secondary) }
                if loading { ProgressView("正在查询实际可用画质…") }
                ForEach(choices) { q in
                    Button {
                        do { downloads.enqueue([try Bilibili.select(work,quality:q)]); dismiss() } catch { self.error = DownloadManager.safeError(error) }
                    } label:{ VStack(alignment:.leading,spacing:5) { Text(q.label); Text(q.available ? (q.video?.quality ?? "") + " · " + (q.video?.codec ?? "") : q.reason).font(.caption).foregroundStyle(.secondary) } }.disabled(!q.available)
                }
                if !error.isEmpty { Text(error).foregroundStyle(MemoStyle.red) }
                if !loading && choices.isEmpty && error.isEmpty { Text("当前会话未返回可用画质，请登录后重试") }
            }
            .navigationTitle("画质与下载").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("关闭") { dismiss() } }
            .task { do { choices = try await PlatformClient.shared.qualities(work) } catch { self.error = DownloadManager.safeError(error) }; loading = false }
        }
    }
}
struct DownloadQueueView:View {
    @EnvironmentObject var downloads:DownloadManager
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            List {
                Section { Text("文件传输由 iOS 后台下载管理。新的平台解析和音视频合成可能需要返回应用；系统强制退出后请重开 Memo。已完成的图集页会在重试时复用。").font(.caption).foregroundStyle(.secondary) }
                ForEach(downloads.jobs) { job in
                    VStack(alignment:.leading,spacing:8) {
                        Text(job.work.title).font(.subheadline).lineLimit(2)
                        HStack { Text(job.work.platform.label + " · " + (job.work.qualityLabel.isEmpty ? "原文件" : job.work.qualityLabel)); Spacer(); Text(job.state) }.font(.caption).foregroundStyle(.secondary)
                        if job.wanted {
                            if job.expected > 0 { ProgressView(value:Double(job.received),total:Double(job.expected)) }
                            HStack { Text(ByteCountFormatter.string(fromByteCount:job.received,countStyle:.file)).font(.caption.monospacedDigit()); Spacer(); Button("暂停") { downloads.cancel(job.id) } }
                        } else if !job.complete { Button("重试／继续") { downloads.retry(job.id) } }
                        if !job.error.isEmpty { Text(job.error).font(.caption).foregroundStyle(MemoStyle.red) }
                    }.padding(.vertical,4)
                }
                if downloads.jobs.isEmpty { ContentUnavailableView("队列是空的",systemImage:"arrow.down.circle",description:Text("从作品页选择内容开始下载。")) }
            }
            .navigationTitle("下载队列").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } }; ToolbarItem(placement:.topBarTrailing) { Button("清理记录") { downloads.removeFinished() } } }
        }
    }
}
