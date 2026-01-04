import Foundation
import SwiftUI

class BatchConversionState: ObservableObject {
    @Published var isConverting: Bool = false
    @Published var isPaused: Bool = false
    @Published var totalCount: Int = 0
    @Published var convertedCount: Int = 0
    @Published var failedCount: Int = 0
    @Published var currentProgress: Double = 0.0
    @Published var selectedDate: Date?
    @Published var statusMessage: String = "准备就绪"
    @Published var currentProcessingIndex: Int = 0
    
    // 计算待转换数量
    var pendingCount: Int {
        return totalCount - convertedCount - failedCount
    }
    
    // 重置状态
    func reset() {
        isConverting = false
        isPaused = false
        totalCount = 0
        convertedCount = 0
        failedCount = 0
        currentProgress = 0.0
        currentProcessingIndex = 0
        statusMessage = "准备就绪"
    }
    
    // 更新进度
    func updateProgress(converted: Int, failed: Int, total: Int) {
        convertedCount = converted
        failedCount = failed
        totalCount = total
        currentProcessingIndex = converted + failed
        
        if total > 0 {
            currentProgress = Double(convertedCount + failedCount) / Double(totalCount)
        }
        
        updateStatusMessage()
    }
    
    // 更新状态消息
    private func updateStatusMessage() {
        if isPaused {
            statusMessage = "已暂停 - 已转换: \(convertedCount), 失败: \(failedCount), 剩余: \(pendingCount)"
        } else if isConverting {
            statusMessage = "转换中... 已转换: \(convertedCount), 失败: \(failedCount), 剩余: \(pendingCount)"
        } else if convertedCount > 0 || failedCount > 0 {
            statusMessage = "转换完成 - 成功: \(convertedCount), 失败: \(failedCount)"
        } else {
            statusMessage = "准备就绪"
        }
    }
    
    // 开始转换
    func start() {
        isConverting = true
        isPaused = false
        updateStatusMessage()
    }
    
    // 暂停转换
    func pause() {
        isPaused = true
        updateStatusMessage()
    }
    
    // 恢复转换
    func resume() {
        isPaused = false
        updateStatusMessage()
    }
    
    // 停止转换
    func stop() {
        isConverting = false
        isPaused = false
        updateStatusMessage()
    }
}

