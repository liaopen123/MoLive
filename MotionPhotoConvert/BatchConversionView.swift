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
                    StatisticRow(label: "总 Live Photo 数", value: "\(totalLivePhotos)")
                    StatisticRow(label: "已转换", value: "\(conversionState.convertedCount)", color: .green)
                    StatisticRow(label: "失败", value: "\(conversionState.failedCount)", color: .red)
                    StatisticRow(label: "待转换", value: "\(conversionState.pendingCount)", color: .orange)
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
    
    // 加载 Live Photo 数量
    private func loadLivePhotoCount() {
        guard permissionManager.photoLibraryPermissionStatus == .authorized else {
            return
        }
        
        isLoadingCount = true
        Task {
            let count = await LivePhotoFetcher.shared.fetchLivePhotoCount(since: conversionState.selectedDate)
            await MainActor.run {
                totalLivePhotos = count
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
            await BatchConverter.shared.convertBatch(assets: assetsToConvert) { converted, failed, error in
                Task { @MainActor in
                    if !Task.isCancelled {
                        conversionState.updateProgress(converted: converted, failed: failed, total: conversionState.totalCount)
                    }
                }
            }
            
            await MainActor.run {
                conversionState.stop()
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

