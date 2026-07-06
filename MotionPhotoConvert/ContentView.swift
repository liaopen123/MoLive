//
//  ContentView.swift
//  MotionJPEGConvert
//
//  Created by 李龙宇 on 2024/12/3.
//

import SwiftUI
import PhotosUI
import Photos

struct ContentView: View {
    @EnvironmentObject private var permissionManager: PermissionManager
    @StateObject private var conversionState = ConversionState()
    @State private var showingPhotoPicker = false
    @State private var showingFileImporter = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showingShareSheet = false
    @State private var convertedFileURL: URL?
    @State private var showingDatePicker = false
    
    var body: some View {
        NavigationView {
            Group {
                if permissionManager.photoLibraryPermissionStatus == .notDetermined {
                    PermissionRequestView()
                } else if permissionManager.photoLibraryPermissionStatus == .denied {
                    PermissionDeniedView()
                } else {
                    VStack(spacing: 0) {
                        Picker("转换模式", selection: $conversionState.isBatchMode) {
                            Text("单张转换").tag(false)
                            Text("批量转换").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding()
                        
                        if conversionState.isBatchMode {
                            batchConversionView
                        } else {
                            singleConversionView
                        }
                    }
                }
            }
            .navigationTitle(conversionState.isBatchMode ? "批量转换" : "照片转换器")
            .alert("提示", isPresented: $showingAlert) {
                Button("确定", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .sheet(isPresented: $showingShareSheet, onDismiss: {
                // 分享完成后清理临时文件
                if let url = convertedFileURL {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    convertedFileURL = nil
                }
            }) {
                if let url = convertedFileURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: $conversionState.selectedItems,
                maxSelectionCount: 10,
                matching: conversionState.convertMode == .motionJPEGToLive ? .images : .livePhotos
            )
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                Task {
                    await handleFileImport(result)
                }
            }
            .onChange(of: conversionState.selectedItems) { oldValue, newValue in
                Task {
                    await loadTransferables()
                }
            }
        }
    }
    
    private var singleConversionView: some View {
        VStack(spacing: 20) {
            Picker("转换方向", selection: $conversionState.convertMode) {
                Text(ConvertMode.motionJPEGToLive.title).tag(ConvertMode.motionJPEGToLive)
                Text(ConvertMode.liveToMotionJPEG.title).tag(ConvertMode.liveToMotionJPEG)
            }
            .pickerStyle(.menu)
            .padding(.horizontal)
            
            PhotoPickerView(
                conversionState: conversionState,
                showingPhotoPicker: $showingPhotoPicker,
                showingFileImporter: $showingFileImporter
            )
            
            if conversionState.isConverting {
                ProgressView(value: conversionState.conversionProgress) {
                    Text("转换中... \(Int(conversionState.conversionProgress * 100))%")
                }
                .padding()
            }
            
            Button(action: {
                Task {
                    await convertPhotos()
                }
            }) {
                Label("开始转换", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(conversionState.selectedPhotos.isEmpty || conversionState.isConverting)
            .padding()
        }
    }
    
    private var batchConversionView: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("按日期过滤", isOn: Binding(
                    get: { conversionState.filterDate != nil },
                    set: { if !$0 { conversionState.filterDate = nil } else { conversionState.filterDate = Date() } }
                ))
                
                if let filterDate = conversionState.filterDate {
                    DatePicker("起始日期", selection: Binding(
                        get: { filterDate },
                        set: { conversionState.filterDate = $0 }
                    ), displayedComponents: .date)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal)
            
            if conversionState.batchAssets.isEmpty && conversionState.skippedCount == 0 {
                ContentUnavailableView {
                    Label("未发现待转换照片", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("点击下方按钮扫描所有 Live Photo")
                }
            } else {
                List {
                    if conversionState.skippedCount > 0 {
                        Section {
                            HStack {
                                Image(systemName: "forward.circle.fill")
                                    .foregroundColor(.blue)
                                Text("已自动跳过 \(conversionState.skippedCount) 张已转换的照片")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    if !conversionState.batchAssets.isEmpty {
                        Section(header: Text("待处理: \(conversionState.batchAssets.count) 张")) {
                            ForEach(conversionState.batchAssets) { task in
                                HStack {
                                    AssetThumbnailView(asset: task.asset)
                                    VStack(alignment: .leading) {
                                        Text(task.asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "未知日期")
                                            .font(.caption)
                                        if let error = task.error {
                                            Text(error)
                                                .font(.caption2)
                                                .foregroundColor(.red)
                                        }
                                    }
                                    Spacer()
                                    statusIcon(for: task.status)
                                }
                            }
                        }
                    }
                }
            }
            
            VStack(spacing: 12) {
                if conversionState.isConverting {
                    VStack(spacing: 8) {
                        HStack {
                            Text("成功: \(conversionState.successCount)")
                                .foregroundColor(.green)
                            Spacer()
                            Text("失败: \(conversionState.failedCount)")
                                .foregroundColor(.red)
                            Spacer()
                            Text("剩余: \(conversionState.remainingCount)")
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal)
                        
                        ProgressView(value: conversionState.conversionProgress) {
                            Text("批量转换中... \(Int(conversionState.conversionProgress * 100))%")
                                .font(.caption2)
                        }
                    }
                    .padding(.horizontal)
                }
                
                HStack(spacing: 16) {
                    Button(action: {
                        BatchConversionManager.shared.fetchLivePhotos(after: conversionState.filterDate, state: conversionState)
                    }) {
                        Label("扫描相册", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(conversionState.isConverting)
                    
                    Button(action: {
                        clearAllTempFiles()
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .disabled(conversionState.isConverting)
                    
                    if conversionState.batchAssets.contains(where: { $0.status == .failed }) {
                        Button(action: {
                            Task {
                                conversionState.isConverting = true
                                await BatchConversionManager.shared.startBatchConversion(state: conversionState)
                                conversionState.isConverting = false
                            }
                        }) {
                            Label("重试失败项", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(conversionState.isConverting)
                    } else {
                        Button(action: {
                            Task {
                                conversionState.isConverting = true
                                await BatchConversionManager.shared.startBatchConversion(state: conversionState)
                                conversionState.isConverting = false
                            }
                        }) {
                            Label("开始批量转换", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(conversionState.batchAssets.isEmpty || conversionState.isConverting || !conversionState.batchAssets.contains(where: { $0.status == .pending }))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }
    
    @ViewBuilder
    private func statusIcon(for status: ConversionState.BatchTask.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.gray)
        case .converting:
            ProgressView()
                .scaleEffect(0.8)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
        case .skipped:
            Image(systemName: "forward.circle.fill")
                .foregroundColor(.blue)
        }
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            await loadFiles(from: urls)
        case .failure(let error):
            showingAlert = true
            alertMessage = "导入文件失败：\(error.localizedDescription)"
        }
    }
    
    private func loadFiles(from urls: [URL]) async {
        conversionState.selectedPhotos.removeAll()
        conversionState.selectedURLs.removeAll()
        
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                guard let image = UIImage(data: data) else { continue }
                let selectionDirectory = try Converter.shared.createTempDirectory(prefix: "MoLiveSelection")
                let copiedURL = selectionDirectory.appendingPathComponent(url.lastPathComponent)
                try data.write(to: copiedURL, options: .atomic)
                conversionState.selectedPhotos.append(image)
                conversionState.selectedURLs.append(copiedURL)
            } catch {
                print("导入文件失败 \(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
    }
    
    private func loadTransferables() async {
        // 检查权限
        if permissionManager.photoLibraryPermissionStatus != .authorized {
            await withCheckedContinuation { continuation in
                permissionManager.requestPhotoLibraryPermission { granted in
                    if !granted {
                        showingAlert = true
                        alertMessage = "需要相册访问权限才能继续操作。请在设置中允许访问相册。"
                        conversionState.selectedItems.removeAll()
                    }
                    continuation.resume()
                }
            }
            return
        }
        
        conversionState.selectedPhotos.removeAll()
        conversionState.selectedURLs.removeAll()
        
        for (index, item) in conversionState.selectedItems.enumerated() {
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    conversionState.selectedPhotos.append(image)
                    
                    // 创建临时文件
                    let selectionDirectory = try Converter.shared.createTempDirectory(prefix: "MoLiveSelection")
                    let tempURL = selectionDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("jpg")
                    try data.write(to: tempURL)
                    conversionState.selectedURLs.append(tempURL)
                    
                    // 更新进度
                    conversionState.conversionProgress = Double(index + 1) / Double(conversionState.selectedItems.count)
                }
            } catch {
                print("加载第 \(index + 1) 张图片失败：\(error.localizedDescription)")
            }
        }
        
        if conversionState.selectedPhotos.isEmpty {
            showingAlert = true
            alertMessage = "没有成功导入任何图片，请重试。"
        }
    }
    
    private func convertPhotos() async {
        conversionState.isConverting = true
        conversionState.conversionProgress = 0
        
        do {
            switch conversionState.convertMode {
            case .motionJPEGToLive:
                if let url = conversionState.selectedURLs.first {
                    try await MotionJPEGToLiveConverter.shared.convert(from: url)
                    showingAlert = true
                    alertMessage = "转换成功！Live Photo 已保存到相册。"
                }
            case .liveToMotionJPEG:
                if let item = conversionState.selectedItems.first {
                    let processedURL = try await LiveToMotionJPEGConverter.shared.convert(from: item)
                    convertedFileURL = processedURL
                    showingShareSheet = true
                }
            }
        } catch let error as NSError {
            showingAlert = true
            
            if error.domain == "PHPhotosErrorDomain" {
                switch error.code {
                case -1:
                    alertMessage = "保存失败。请尝试以下步骤：\n1. 删除应用重新安装\n2. 在设置中关闭相册权限再重新打开\n3. 重启设备后重试"
                case 3300:
                    alertMessage = "无法保存到相册，请检查存储空间是否充足"
                default:
                    alertMessage = "保存到相册失败：\(error.localizedDescription)"
                }
            } else {
                alertMessage = "转换失败：\(error.localizedDescription)"
            }
        }
        
        conversionState.isConverting = false
        conversionState.conversionProgress = 1.0
    }
    
    private func clearAllTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let ownedPrefixes = ["LivePhotoConvert_", "MotionJPEGConvert_", "LivePhotoTemp_", "MoLiveSelection_"]
        do {
            let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            for file in files where ownedPrefixes.contains(where: file.lastPathComponent.hasPrefix) {
                try? FileManager.default.removeItem(at: file)
            }
            alertMessage = "缓存清理成功！已释放存储空间。"
            showingAlert = true
        } catch {
            alertMessage = "清理失败：\(error.localizedDescription)"
            showingAlert = true
        }
    }
}

struct AssetThumbnailView: View {
    let asset: PHAsset
    @State private var image: UIImage? = nil
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: 40, height: 40)
        .cornerRadius(4)
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        let manager = PHImageManager.default()
        let option = PHImageRequestOptions()
        option.isSynchronous = false
        option.deliveryMode = .opportunistic
        
        manager.requestImage(for: asset, targetSize: CGSize(width: 80, height: 80), contentMode: .aspectFill, options: option) { result, _ in
            self.image = result
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .previewDevice("iPhone 14 Pro")
            .environmentObject(PermissionManager())
    }
}
