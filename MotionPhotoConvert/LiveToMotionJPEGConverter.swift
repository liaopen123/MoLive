import Foundation
import Photos
import PhotosUI
import SwiftUI

class LiveToMotionJPEGConverter {
    static let shared = LiveToMotionJPEGConverter()
    private init() {}
    
    func convert(from item: PhotosPickerItem) async throws -> URL {
        // 从 PhotosPickerItem 获取 Live Photo
        guard let livePhoto = try await item.loadTransferable(type: PHLivePhoto.self) else {
            throw NSError(domain: "PhotoConverterError",
                         code: 1002,
                         userInfo: [NSLocalizedDescriptionKey: "无法加载 Live Photo"])
        }
        
        // 转换 Live Photo 到 Motion JPEG
        return try await Converter.shared.convertLivePhotoToMotionJPEG(from: livePhoto)
    }
    
    // 从 PHAsset 直接转换
    func convert(from asset: PHAsset) async throws -> URL {
        // 使用 LivePhotoFetcher 加载 Live Photo
        let livePhoto = try await LivePhotoFetcher.shared.loadLivePhoto(from: asset)
        
        // 转换 Live Photo 到 Motion JPEG
        return try await Converter.shared.convertLivePhotoToMotionJPEG(from: livePhoto)
    }
} 