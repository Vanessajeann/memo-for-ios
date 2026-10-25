import SwiftUI
import MemoCore
import AVKit
import Photos
import UniformTypeIdentifiers
import ImageIO

struct LocalRecording:Identifiable { let url:URL; var id:String { url.path } }
struct RecordingLibraryView:View {
    @EnvironmentObject var recorder:RecordingManager
    @EnvironmentObject var downloads:DownloadManager
    @State private var playing:LocalRecording?
    @State private var showingImage:LocalRecording?
    @State private var deleting = false
    @State private var pendingDelete: [URL] = []
    @State private var choosingFolder = false
    @State private var exportFiles: [URL] = []
    @State private var exporting = false
    @State private var importing = false
    @State private var selecting = ProcessInfo.processInfo.environment["MEMO_UI_LIBRARY_SELECTION"] == "1"
    @State private var queue = false
    @State private var selected = Set<URL>()
    @State private var saving = Set<URL>()
    @State private var search = ""
    @State private var category = "全部"
    @AppStorage("library.grid") private var grid = false
    private var files:[URL] { (recorder.files() + downloads.files()).filter { (search.isEmpty || title($0).localizedCaseInsensitiveContains(search)) && (category == "全部" || (category == "录像" ? !isImage($0) : isImage($0))) } }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    HStack {
                        VStack(alignment:.leading,spacing:4) { Text("YOUR COLLECTION").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(MemoStyle.blue); Text("\(files.count) 个文件 · 保存在本机").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("下载队列",systemImage:"arrow.down.circle") { queue = true }.labelStyle(.iconOnly).font(.title3).frame(width:44,height:44)
                    }
                    Picker("类型",selection:$category) { Text("全部").tag("全部"); Text("录像").tag("录像"); Text("图片").tag("图片") }.pickerStyle(.segmented)
                    if selecting { batchActions }
                    if files.isEmpty { ContentUnavailableView("收藏从这里开始",systemImage:"film.stack",description:Text("完成的直播录像、视频与图集会显示在这里。录制中的片段会在保存后出现。")) }
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:12),count:grid ? 3 : 1),spacing:12) {
                        ForEach(files,id:\.self) { file in fileCard(file) }
                    }
                }.padding(18)
            }
            .memoPage().navigationTitle("录像")
            .searchable(text:$search,prompt:"搜索录像与作品")
            .toolbar {
                ToolbarItemGroup(placement:.topBarTrailing) {
                    Button(selecting ? "完成" : "选择") { selecting.toggle(); if !selecting { selected = [] } }
                    Menu {
                        Button("导入录像",systemImage:"square.and.arrow.down") { choosingFolder = false; importing = true }
                        Button(grid ? "切换列表" : "切换网格",systemImage:grid ? "list.bullet" : "square.grid.3x3") { grid.toggle() }
                        if selecting { Button("全选当前结果") { selected = Set(files) } }
                    } label:{ Image(systemName:"ellipsis.circle") }
                }
            }
            .sheet(item:$playing) { LocalRecordingPlayer(recording:$0) }
            .sheet(item:$showingImage) { item in
                ImageGalleryView(initial:item.url,files:files.filter { isImage($0) && $0.deletingLastPathComponent() == item.url.deletingLastPathComponent() }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            }
            .sheet(isPresented:$queue) { DownloadQueueView() }
            .fileImporter(isPresented:$importing,allowedContentTypes:choosingFolder ? [.folder] : [.movie,.data],allowsMultipleSelection:!choosingFolder) { result in
                switch result {
                case .success(let urls):
                    if choosingFolder { if let folder = urls.first { export(to:folder) } }
                    else { for url in urls { recorder.importFile(url) } }
                case .failure: recorder.message = choosingFolder ? "未能选择保存位置，请重试。" : "未能导入文件，请重试。"
                }
            }
            .confirmationDialog("删除所选 \(pendingDelete.count) 个文件？",isPresented:$deleting,titleVisibility:.visible) {
                Button("删除 \(pendingDelete.count) 个文件",role:.destructive) { deletePending() }
                Button("取消",role:.cancel) { pendingDelete = [] }
            } message:{ Text("删除 Memo 内的本机文件，无法撤销；已保存到相册或其他位置的副本不受影响。") }
            .onAppear { if ProcessInfo.processInfo.environment["MEMO_UI_CAPTURE"] == "1", ProcessInfo.processInfo.environment["MEMO_UI_LIBRARY_SELECTION"] == "1" { selected = Set(files) } }
            .onChange(of:files) { _,new in selected.formIntersection(new) }
        }
    }
    private var batchActions:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Button(!files.isEmpty && selected.count == files.count ? "取消全选" : "全选") {
                    if !files.isEmpty && selected.count == files.count { selected = [] } else { selected = Set(files) }
                }.disabled(files.isEmpty || exporting || !saving.isEmpty)
                Spacer()
                Text("已选 \(selected.count) / \(files.count)").foregroundStyle(.secondary)
            }
            HStack {
                Menu {
                    Button("保存到相册",systemImage:"photo") { savePhotos(Array(selected)) }
                    Button("保存到文件…",systemImage:"folder") {
                        exportFiles = selected.sorted { $0.path < $1.path }; choosingFolder = true; importing = true
                    }
                } label:{ Label(exporting ? "保存中…" : "保存／下载",systemImage:"arrow.down.to.line") }
                Spacer(minLength:4)
                ShareLink(items:selected.sorted { $0.path < $1.path }) { Label("分享",systemImage:"square.and.arrow.up") }
                Spacer(minLength:4)
                Button("删除",systemImage:"trash",role:.destructive) { requestDelete(Array(selected)) }
            }.disabled(selected.isEmpty || exporting || !saving.isEmpty)
            Text("全选仅针对当前搜索和类型筛选结果；文件已在本机，保存可导出到相册或“文件”。").font(.caption2).foregroundStyle(.secondary)
        }.font(.subheadline).padding(14).glassCard(radius:18)
    }
    private func requestDelete(_ files:[URL]) { pendingDelete = files; deleting = !files.isEmpty }
    private func deletePending() {
        let targets = pendingDelete; pendingDelete = []
        var failed = Set<URL>()
        for file in targets {
            let removed = LocalFiles.contains(file,in:recorder.directory) ? recorder.delete(file) : downloads.delete(file)
            if !removed { failed.insert(file) }
        }
        selected.subtract(targets); selected.formUnion(failed)
        recorder.message = "已删除 \(targets.count - failed.count)/\(targets.count) 个文件" + (failed.isEmpty ? "" : "。失败项已保留，请确认文件未被录制、整理或其他操作占用后重试。")
    }
    private func export(to folder:URL) {
        let targets = exportFiles; exportFiles = []; exporting = true
        Task { @MainActor in
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() }; exporting = false }
            let count = await Task.detached(priority:.utility) {
                var count = 0
                for file in targets {
                    var output = folder.appendingPathComponent(file.lastPathComponent)
                    if FileManager.default.fileExists(atPath:output.path) { output = folder.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent) }
                    do { try FileManager.default.copyItem(at:file,to:output); count += 1 } catch { }
                }
                return count
            }.value
            recorder.message = "已保存 \(count)/\(targets.count) 个文件；Memo 内的原文件保留。"
        }
    }
    private func fileCard(_ file:URL)->some View {
        VStack(alignment:.leading,spacing:9) {
            HStack(alignment:.top,spacing:12) {
                Button { if selecting { if !selected.insert(file).inserted { selected.remove(file) } } else { open(file) } } label:{
                    ZStack {
                        RoundedRectangle(cornerRadius:12).fill(MemoStyle.blue.opacity(0.10))
                        if isImage(file) { FileThumbnail(file:file) }
                        else { Image(systemName:file.pathExtension == "mkv" ? "film" : "play.fill").font(.title3).foregroundStyle(MemoStyle.blue) }
                    }.frame(width:grid ? nil : 55,height:grid ? 110 : 68).clipped().clipShape(RoundedRectangle(cornerRadius:12))
                }.buttonStyle(.plain).accessibilityLabel("预览 \(title(file))")
                if !grid { fileLabels(file); Spacer(minLength:0) }
                if selecting { Button { if !selected.insert(file).inserted { selected.remove(file) } } label:{ Image(systemName:selected.contains(file) ? "checkmark.circle.fill" : "circle").font(.title3).frame(width:32,height:38) }.buttonStyle(.plain) }
            }
            if grid { fileLabels(file) }
            if !selecting {
                HStack(spacing:8) {
                    if file.pathExtension == "mkv" { Button("整理 MP4") { recorder.convertFile(file) } }
                    else { Button("相册") { savePhotos([file]) }.disabled(saving.contains(file) || exporting) }
                    Spacer(minLength:0)
                    ShareLink(item:file) { Image(systemName:"square.and.arrow.up") }.accessibilityLabel("分享或保存到 Files")
                    Button(role:.destructive) { requestDelete([file]) } label:{ Image(systemName:"trash") }.disabled(saving.contains(file) || exporting)
                }.font(.caption).buttonStyle(.borderless)
            }
        }.padding(12).glassCard(radius:21)
    }
    private func fileLabels(_ file:URL)->some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title(file)).font(grid ? .caption : .subheadline.weight(.medium)).lineLimit(2)
            let size = Int64((try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
            Text(file.pathExtension.uppercased() + " · " + ByteCountFormatter.string(fromByteCount:size,countStyle:.file)).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func title(_ file:URL)->String {
        if let job = downloads.jobs.first(where:{ $0.id == file.deletingLastPathComponent().lastPathComponent }) { return job.work.title + (isImage(file) ? " · " + file.deletingPathExtension().lastPathComponent : "") }
        return file.lastPathComponent
    }
    private func open(_ file:URL) { if isImage(file) { showingImage = LocalRecording(url:file) } else if file.pathExtension == "mkv" { recorder.convertFile(file) } else { playing = LocalRecording(url:file) } }
    private func isImage(_ file:URL)->Bool { ["jpg","jpeg","png","webp","heic","avif"].contains(file.pathExtension.lowercased()) }
    private func savePhotos(_ files:[URL]) {
        let supported = files.filter { isImage($0) || $0.pathExtension == "mp4" }.filter { !saving.contains($0) }
        guard !supported.isEmpty else { recorder.message = "请先将 MKV 整理为 MP4"; return }
        saving.formUnion(supported)
        Task { @MainActor in
            defer { saving.subtract(supported) }
            let permission = await PHPhotoLibrary.requestAuthorization(for:.addOnly)
            guard permission == .authorized || permission == .limited else { recorder.message = "请在系统设置中允许 Memo 添加照片和视频。"; return }
            var count = 0
            for file in supported {
                do {
                    let image = isImage(file)
                    try await PHPhotoLibrary.shared().performChanges { PHAssetCreationRequest.forAsset().addResource(with:image ? .photo : .video,fileURL:file,options:nil) }
                    count += 1
                } catch { /* Continue batch; files remain in Memo even if Photos rejects a format. */ }
            }
            recorder.message = "已保存 \(count)/\(supported.count) 个文件到相册" + (count < supported.count ? "。部分格式系统不接受，可通过分享保存到 Files；原文件均保留。" : "")
        }
    }
}
struct LocalRecordingPlayer:View {
    let recording:LocalRecording
    @Environment(\.dismiss) private var dismiss
    @State private var player:AVPlayer?
    var body:some View {
        NavigationStack {
            VideoPlayer(player:player).background(.black)
                .navigationTitle(recording.url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } }; ToolbarItem(placement:.topBarTrailing) { ShareLink(item:recording.url) } }
                .onAppear { player = AVPlayer(url:recording.url); player?.play() }
                .onDisappear { player?.pause(); player = nil }
        }
    }
}
struct ImageGalleryView:View {
    let initial:URL, files:[URL]
    @Environment(\.dismiss) private var dismiss
    @State private var selected = 0
    var body:some View {
        NavigationStack {
            TabView(selection:$selected) {
                ForEach(Array(files.enumerated()),id:\.element) { index,file in
                    ZoomImage(file:file).tag(index)
                }
            }.tabViewStyle(.page).background(.black).ignoresSafeArea(edges:.bottom)
            .navigationTitle("\(selected+1) / \(files.count)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } }; ToolbarItem(placement:.topBarTrailing) { if selected < files.count { ShareLink(item:files[selected]) } } }
            .onAppear { selected = files.firstIndex(of:initial) ?? 0 }
        }
    }
}
struct ZoomImage:View {
    let file:URL
    @State private var scale:CGFloat = 1
    var body:some View {
        GeometryReader { g in
            if let image = UIImage(contentsOfFile:file.path) {
                Image(uiImage:image).resizable().scaledToFit().frame(width:g.size.width,height:g.size.height).scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { scale = max(1,min(5,$0.magnification)) }.onEnded { _ in if scale < 1.05 { scale = 1 } })
                    .onTapGesture(count:2) { withAnimation { scale = scale == 1 ? 2 : 1 } }
            } else { ContentUnavailableView("系统无法预览此格式",systemImage:"photo",description:Text("可通过分享保存原文件。")) }
        }.clipped()
    }
}

struct FileThumbnail:View {
    let file:URL
    @State private var image:UIImage?
    var body:some View {
        Group { if let image { Image(uiImage:image).resizable().scaledToFill() } else { Color.clear } }
            .task(id:file) {
                image = await Task.detached(priority:.utility) {
                    guard let source = CGImageSourceCreateWithURL(file as CFURL,nil), let cg = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:480,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { return nil as UIImage? }
                    return UIImage(cgImage:cg)
                }.value
            }
    }
}
