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
    @Published var validationSummary: String?
    
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
    
    private let legacyHistoryKey = "ConvertedLivePhotoIDs"
    
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
        clearSelectedMedia()

        batchAssets.removeAll()
        conversionProgress = 0
        validationSummary = nil
        isConverting = false
        successCount = 0
        failedCount = 0
        skippedCount = 0
        totalFoundCount = 0
    }

    func clearSelectedMedia() {
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
        validationSummary = nil
    }
    
    // 历史记录管理
    func getConvertedIDs() -> Set<String> {
        if let data = try? Data(contentsOf: historyURL),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            return Set(array)
        }

        let legacy = UserDefaults.standard.stringArray(forKey: legacyHistoryKey) ?? []
        if !legacy.isEmpty {
            persistConvertedIDs(Set(legacy))
            UserDefaults.standard.removeObject(forKey: legacyHistoryKey)
        }
        return Set(legacy)
    }
    
    func saveConvertedID(_ id: String) {
        var ids = getConvertedIDs()
        ids.insert(id)
        persistConvertedIDs(ids)
    }

    func clearConversionHistory() {
        try? FileManager.default.removeItem(at: historyURL)
        UserDefaults.standard.removeObject(forKey: legacyHistoryKey)
    }

    private var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("MoLive", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("conversion-history.json")
    }

    private func persistConvertedIDs(_ ids: Set<String>) {
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }
}
