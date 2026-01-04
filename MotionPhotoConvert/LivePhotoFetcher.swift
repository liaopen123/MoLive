import Foundation
import Photos
import UIKit

class LivePhotoFetcher {
    static let shared = LivePhotoFetcher()
    private init() {}
    
    // 获取所有或指定日期后的 Live Photo
    func fetchAllLivePhotos(since date: Date? = nil) async -> [PHAsset] {
        var assets: [PHAsset] = []
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        // 如果指定了日期，添加日期筛选
        if let date = date {
            fetchOptions.predicate = NSPredicate(format: "creationDate >= %@", date as NSDate)
        }
        
        // 获取所有 Live Photo
        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        
        // 遍历并筛选出 Live Photo
        fetchResult.enumerateObjects { asset, _, _ in
            // 检查是否为 Live Photo（通过资源类型判断）
            let resources = PHAssetResource.assetResources(for: asset)
            let hasPairedVideo = resources.contains { $0.type == .pairedVideo }
            
            if hasPairedVideo {
                assets.append(asset)
            }
        }
        
        return assets
    }
    
    // 获取 Live Photo 数量（用于快速显示）
    func fetchLivePhotoCount(since date: Date? = nil) async -> Int {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        if let date = date {
            fetchOptions.predicate = NSPredicate(format: "creationDate >= %@", date as NSDate)
        }
        
        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        var count = 0
        
        fetchResult.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let hasPairedVideo = resources.contains { $0.type == .pairedVideo }
            
            if hasPairedVideo {
                count += 1
            }
        }
        
        return count
    }
    
    // 从 PHAsset 加载 PHLivePhoto
    func loadLivePhoto(from asset: PHAsset) async throws -> PHLivePhoto {
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            
            PHImageManager.default().requestLivePhoto(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { livePhoto, info in
                if let livePhoto = livePhoto {
                    continuation.resume(returning: livePhoto)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: ConversionError.invalidInput)
                }
            }
        }
    }
}

