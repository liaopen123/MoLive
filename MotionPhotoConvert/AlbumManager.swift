import Foundation
import Photos

class AlbumManager {
    static let shared = AlbumManager()
    private init() {}
    
    // 默认相册名称
    private let defaultAlbumName = "MoLive 转换照片"
    
    // 获取或创建相册
    func getOrCreateAlbum(name: String? = nil) async throws -> PHAssetCollection {
        let albumName = name ?? defaultAlbumName
        
        // 先尝试查找现有相册
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title == %@", albumName)
        
        let fetchResult = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: fetchOptions
        )
        
        if let existingAlbum = fetchResult.firstObject {
            return existingAlbum
        }
        
        // 如果不存在，创建新相册
        return try await createAlbum(name: albumName)
    }
    
    // 创建新相册
    private func createAlbum(name: String) async throws -> PHAssetCollection {
        var albumPlaceholder: PHObjectPlaceholder?
        
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            albumPlaceholder = request.placeholderForCreatedAssetCollection
        }
        
        guard let placeholder = albumPlaceholder,
              let album = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [placeholder.localIdentifier],
                options: nil
              ).firstObject else {
            throw NSError(
                domain: "AlbumManagerError",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "创建相册失败"]
            )
        }
        
        return album
    }
    
    // 保存文件到相册
    func saveToAlbum(fileURL: URL, album: PHAssetCollection) async throws {
        var assetPlaceholder: PHObjectPlaceholder?
        
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
            assetPlaceholder = request?.placeholderForCreatedAsset
            
            if let placeholder = assetPlaceholder,
               let albumChangeRequest = PHAssetCollectionChangeRequest(for: album) {
                albumChangeRequest.addAssets([placeholder] as NSArray)
            }
        }
        
        // 验证保存是否成功
        guard assetPlaceholder != nil else {
            throw NSError(
                domain: "AlbumManagerError",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "保存图片到相册失败"]
            )
        }
    }
    
    // 批量保存文件到相册
    func saveToAlbum(fileURLs: [URL], album: PHAssetCollection) async throws {
        var assetPlaceholders: [PHObjectPlaceholder] = []
        
        try await PHPhotoLibrary.shared().performChanges {
            for fileURL in fileURLs {
                if let request = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL),
                   let placeholder = request.placeholderForCreatedAsset {
                    assetPlaceholders.append(placeholder)
                }
            }
            
            if let albumChangeRequest = PHAssetCollectionChangeRequest(for: album) {
                albumChangeRequest.addAssets(assetPlaceholders as NSArray)
            }
        }
        
        guard !assetPlaceholders.isEmpty else {
            throw NSError(
                domain: "AlbumManagerError",
                code: 1003,
                userInfo: [NSLocalizedDescriptionKey: "批量保存图片到相册失败"]
            )
        }
    }
}

