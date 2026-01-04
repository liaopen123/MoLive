import SwiftUI
import Photos

struct BatchConversionView: View {
    @StateObject private var conversionState = BatchConversionState()
    @StateObject private var permissionManager = PermissionManager()
    @State private var showingDatePicker = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var totalLivePhotos = 0
    @State private var isLoadingCount = false
    @State private var conversionTask: Task<Void, Never>?
    
    var body: some View {
        VStack(spacing: 20) {
            // 权限检查
            if permissionManager.photoLibraryPermissionStatus == .notDetermined {
                PermissionRequestView()
            } else if permissionManager.photoLibraryPermissionStatus == .denied {
                PermissionDeniedView()
            } else {
                // 主界面
                ScrollView {
                    VStack(spacing: 20) {
                        // 日期选择器
                        dateSelectionSection
                        
                        // 统计信息
                        statisticsSection
                        
                        // 进度显示
                        if conversionState.isConverting || conversionState.convertedCount > 0 {
                            progressSection
                        }
                        
                        // 控制按钮
                        controlButtonsSection
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("批量转换")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: $showingAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            checkPermission()
            if permissionManager.photoLibraryPermissionStatus == .authorized {
                loadLivePhotoCount()
            }
        }
        .onDisappear {
            // 取消正在进行的转换
            conversionTask?.cancel()
        }
    }
    
    // 日期选择区域
    private var dateSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("转换日期范围")
                .font(.headline)
            
            HStack {
                if let date = conversionState.selectedDate {
                    Text("从 \(formatDate(date))")
                        .foregroundColor(.primary)
                } else {
                    Text("转换所有照片")
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: {
                    showingDatePicker.toggle()
                }) {
                    Text(conversionState.selectedDate == nil ? "选择日期" : "更改日期")
                        .buttonStyle(.bordered)
                }
            }
            
            if conversionState.selectedDate != nil {
                Button(action: {
                    conversionState.selectedDate = nil
                    loadLivePhotoCount()
                }) {
                    Text("清除日期筛选")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .sheet(isPresented: $showingDatePicker) {
            DatePickerSheet(
                selectedDate: $conversionState.selectedDate,
                onDateSelected: {
                    loadLivePhotoCount()
                }
            )
        }
    }
    
    // 统计信息区域
    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("统计信息")
                .font(.headline)
            
            if isLoadingCount {
                HStack {
                    ProgressView()
                    Text("正在加载...")
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    StatisticRow(label: "待转换总数", value: "\(totalLivePhotos)")
                    StatisticRow(label: "已转换", value: "\(conversionState.convertedCount)", color: .green)
                    StatisticRow(label: "失败", value: "\(conversionState.failedCount)", color: .red)
                    StatisticRow(label: "剩余", value: "\(conversionState.pendingCount)", color: .orange)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    // 进度显示区域
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("转换进度")
                .font(.headline)
            
            ProgressView(value: conversionState.currentProgress) {
                HStack {
                    Text(conversionState.statusMessage)
                        .font(.caption)
                    Spacer()
                    Text("\(Int(conversionState.currentProgress * 100))%")
                        .font(.caption)
                }
            }
            .progressViewStyle(.linear)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    // 控制按钮区域
    private var controlButtonsSection: some View {
        VStack(spacing: 12) {
            if conversionState.isConverting {
                HStack(spacing: 12) {
                    if conversionState.isPaused {
                        Button(action: resumeConversion) {
                            Label("继续", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    } else {
                        Button(action: pauseConversion) {
                            Label("暂停", systemImage: "pause.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Button(action: stopConversion) {
                        Label("停止", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            } else {
                Button(action: startConversion) {
                    Label("开始转换", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(totalLivePhotos == 0 || isLoadingCount)
            }
            
            // 重试失败的文件
            if !conversionState.isConverting && conversionState.hasFailedAssets {
                Button(action: retryFailedConversion) {
                    Label("重试失败的文件 (\(conversionState.failedAssets.count))", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            
            if conversionState.convertedCount > 0 || conversionState.failedCount > 0 {
                Button(action: resetConversion) {
                    Text("重置")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
    
    // 格式化日期
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    // 检查权限
    private func checkPermission() {
        permissionManager.photoLibraryPermissionStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }
    
    // 加载 Live Photo 数量（排除已转换的）
    private func loadLivePhotoCount() {
        guard permissionManager.photoLibraryPermissionStatus == .authorized else {
            return
        }
        
        isLoadingCount = true
        Task {
            // 获取所有 Live Photo
            let allAssets = await LivePhotoFetcher.shared.fetchAllLivePhotos(since: conversionState.selectedDate)
            
            // 获取已转换的记录
            let recordManager = ConversionRecordManager.shared
            let convertedIdentifiers = recordManager.getAllConvertedIdentifiers()
            
            // 过滤掉已转换的
            let pendingAssets = allAssets.filter { !convertedIdentifiers.contains($0.localIdentifier) }
            
            await MainActor.run {
                // 总数应该是待转换的数量（不包含已转换的）
                totalLivePhotos = pendingAssets.count
                isLoadingCount = false
            }
        }
    }
    
    // 开始转换
    private func startConversion() {
        guard permissionManager.photoLibraryPermissionStatus == .authorized else {
            showingAlert = true
            alertMessage = "需要相册访问权限"
            return
        }
        
        conversionState.start()
        conversionState.totalCount = totalLivePhotos
        
        conversionTask = Task {
            // 获取所有需要转换的 Live Photo
            let assets = await LivePhotoFetcher.shared.fetchAllLivePhotos(since: conversionState.selectedDate)
            
            // 过滤已转换的
            let recordManager = ConversionRecordManager.shared
            let convertedIdentifiers = recordManager.getAllConvertedIdentifiers()
            let assetsToConvert = assets.filter { !convertedIdentifiers.contains($0.localIdentifier) }
            
            await MainActor.run {
                conversionState.totalCount = assetsToConvert.count
            }
            
            // 执行批量转换
            await BatchConverter.shared.convertBatch(assets: assetsToConvert) { converted, failed, total, failedAsset, error in
                Task { @MainActor in
                    if !Task.isCancelled {
                        // 使用 BatchConverter 返回的 total，确保一致性
                        conversionState.updateProgress(converted: converted, failed: failed, total: total)
                        
                        // 如果有失败的 asset，添加到失败列表
                        if let failedAsset = failedAsset {
                            conversionState.addFailedAsset(failedAsset)
                        }
                    }
                }
            }
            
            await MainActor.run {
                conversionState.stop()
                // 重试完成后，重新加载统计信息（排除已转换的）
                loadLivePhotoCount()
            }
        }
    }
    
    // 暂停转换
    private func pauseConversion() {
        conversionState.pause()
        BatchConverter.shared.setPaused(true)
    }
    
    // 恢复转换
    private func resumeConversion() {
        conversionState.resume()
        BatchConverter.shared.setPaused(false)
    }
    
    // 停止转换
    private func stopConversion() {
        conversionTask?.cancel()
        conversionState.stop()
    }
    
    // 重置转换
    private func resetConversion() {
        conversionState.reset()
        loadLivePhotoCount()
    }
    
    // 重试失败的文件
    private func retryFailedConversion() {
        guard permissionManager.photoLibraryPermissionStatus == .authorized else {
            showingAlert = true
            alertMessage = "需要相册访问权限"
            return
        }
        
        guard !conversionState.failedAssets.isEmpty else {
            return
        }
        
        // 保存失败的 assets 列表（创建副本）
        let failedAssets = Array(conversionState.failedAssets)
        let retryCount = failedAssets.count
        
        // 记录重试前的状态
        let previousConverted = conversionState.convertedCount
        let previousFailed = conversionState.failedCount
        
        // 清空失败列表（重试过程中会重新填充）
        conversionState.failedAssets.removeAll()
        conversionState.failedCount = 0
        
        // 更新总数（只重试失败的文件）
        conversionState.totalCount = retryCount
        conversionState.start()
        
        conversionTask = Task {
            // 执行批量转换（只转换失败的文件）
            await BatchConverter.shared.convertBatch(assets: failedAssets) { converted, failed, total, failedAsset, error in
                Task { @MainActor in
                    if !Task.isCancelled {
                        // 更新进度
                        // 已转换数 = 之前的已转换数 + 重试成功的数量
                        // 失败数 = 重试失败的数量
                        conversionState.updateProgress(
                            converted: previousConverted + converted,
                            failed: failed,
                            total: conversionState.totalCount
                        )
                        
                        // 如果有失败的 asset，添加到失败列表
                        if let failedAsset = failedAsset {
                            conversionState.addFailedAsset(failedAsset)
                        }
                    }
                }
            }
            
            await MainActor.run {
                conversionState.stop()
                // 重试完成后，重新加载统计信息（排除已转换的）
                loadLivePhotoCount()
            }
        }
    }
}

// 日期选择器 Sheet
struct DatePickerSheet: View {
    @Binding var selectedDate: Date?
    @Environment(\.dismiss) var dismiss
    @State private var tempDate: Date = Date()
    var onDateSelected: () -> Void
    
    var body: some View {
        NavigationView {
            VStack {
                DatePicker(
                    "选择日期",
                    selection: $tempDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding()
                
                Spacer()
            }
            .navigationTitle("选择日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("确定") {
                        selectedDate = tempDate
                        onDateSelected()
                        dismiss()
                    }
                }
            }
        }
    }
}

// 统计信息行
struct StatisticRow: View {
    let label: String
    let value: String
    var color: Color = .primary
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
    }
}

#Preview {
    NavigationView {
        BatchConversionView()
    }
}

