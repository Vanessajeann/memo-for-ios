import SwiftUI
import AVKit
import Photos
import UniformTypeIdentifiers

struct LocalRecording: Identifiable {
    let url: URL
    var id: String { url.path }
}
struct RecordingLibraryView: View {
    @EnvironmentObject var recorder: RecordingManager
    @State private var playing: LocalRecording?
    @State private var deleting: URL?
    @State private var importing = false
    @State private var saving = Set<URL>()
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("已完成的录像会显示在这里。录制、整理中的文件不会被删除或分享；异常留下的 MKV 可以重新整理。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(recorder.files(), id: \.self) { file in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(file.lastPathComponent).font(.caption).lineLimit(2)
                        HStack {
                            if file.pathExtension == "mp4" {
                                Button("播放") { playing = LocalRecording(url: file) }
                                Button(saving.contains(file) ? "保存中" : "相册") { savePhoto(file) }.disabled(saving.contains(file))
                            } else {
                                Button("整理为 MP4") { recorder.convertFile(file) }
                            }
                            ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                            Spacer()
                            Button(role: .destructive) { deleting = file } label: { Image(systemName: "trash") }
                                .disabled(saving.contains(file))
                        }.buttonStyle(.borderless)
                    }
                }
                if recorder.files().isEmpty { Text("暂无已完成录像") }
            }
            .navigationTitle("录像")
            .toolbar { Button("导入") { importing = true } }
            .sheet(item: $playing) { recording in
                LocalRecordingPlayer(recording: recording)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .data]) { result in
                switch result {
                case .success(let url): recorder.importFile(url)
                case .failure(let error): recorder.message = error.localizedDescription
                }
            }
            .confirmationDialog("删除此录像？删除后无法恢复，请先确认已经导出。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("删除", role: .destructive) { if let file = deleting { recorder.delete(file) }; deleting = nil }
            }
        }
    }
    private func savePhoto(_ file: URL) {
        guard !saving.contains(file) else { return }
        saving.insert(file)
        Task { @MainActor in
            let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard permission == .authorized || permission == .limited else {
                recorder.message = "请在系统设置中允许 Memo 添加照片和视频。"; saving.remove(file); return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
                }
                recorder.message = "已保存至系统相册"
            } catch { recorder.message = "相册保存失败，原文件仍保留：\(error.localizedDescription)" }
            saving.remove(file)
        }
    }
}
struct LocalRecordingPlayer: View {
    let recording: LocalRecording
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var recorder: RecordingManager
    @State private var player: AVPlayer?
    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .toolbar { Button("关闭") { dismiss() } }
                .onAppear { player = AVPlayer(url: recording.url); player?.play() }
                .onDisappear { player?.pause(); player = nil }
        }
    }
}
