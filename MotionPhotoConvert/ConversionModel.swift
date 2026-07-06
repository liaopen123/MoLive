import Foundation
import UIKit
import PhotosUI
import SwiftUI
import Photos

enum ConvertMode {
    case motionJPEGToLive
    case liveToMotionJPEG
    
    var title: String {
        switch self {
        case .motionJPEGToLive:
            return "Motion JPEG → Live Photo"
        case .liveToMotionJPEG:
            return "Live Photo → Motion JPEG"
        }
    }
}

class ConversionState: ObservableObject {
    @Published var selectedItems: [PhotosPickerItem] = []
    @Published var selectedPhotos: [UIImage] = []
    @Published var selectedURLs: [URL] = []
    @Published var isConverting = false
    @Published var conversionProgress: Double = 0
    @Published var convertMode: ConvertMode = .motionJPEGToLive
    
    // 批处理相关
    @Published var batchAssets: [BatchTask] = []
    @Published var isBatchMode = false
    @Published var filterDate: Date? = nil
    @Published var skippedCount = 0
    @Published var totalFoundCount = 0
    @Published var successCount = 0
    @Published var failedCount = 0
    
    var remainingCount: Int {
        let pending = batchAssets.filter { $0.status == .pending }.count
        return pending
    }
    
    private let historyKey = "ConvertedLivePhotoIDs"
    
    struct BatchTask: Identifiable {
        let id: String // PHAsset localIdentifier
        let asset: PHAsset
        var status: Status = .pending
        var error: String?
        
        enum Status: String {
            case pending, converting, success, failed, skipped
        }
    }
    
    func reset() {
        // 清理所有选择的临时文件
        for url in selectedURLs {
            if url.deletingLastPathComponent().lastPathComponent.hasPrefix("MoLiveSelection_") {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            } else if url.isFileURL && url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        selectedItems.removeAll()
        selectedPhotos.removeAll()
        selectedURLs.removeAll()
        batchAssets.removeAll()
        conversionProgress = 0
        isConverting = false
        successCount = 0
        failedCount = 0
        skippedCount = 0
        totalFoundCount = 0
    }
    
    // 历史记录管理
    func getConvertedIDs() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        return Set(array)
    }
    
    func saveConvertedID(_ id: String) {
        var ids = getConvertedIDs()
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: historyKey)
    }
}
