import Foundation
import Photos

class BatchConverter {
    static let shared = BatchConverter()
    private init() {}
    
    // 暂停标志（使用 actor 保证线程安全）
    private actor PauseState {
        var isPaused: Bool = false
        
        func setPaused(_ paused: Bool) {
            isPaused = paused
        }
        
        func checkPaused() -> Bool {
            return isPaused
        }
    }
    
    private let pauseState = PauseState()
    
    // 设置暂停状态（同步方法，内部使用异步）
    func setPaused(_ paused: Bool) {
        Task {
            await pauseState.setPaused(paused)
        }
    }
    
    // 批量转换（顺序执行，一个接一个）
    func convertBatch(
        assets: [PHAsset],
        progressHandler: @escaping (Int, Int, Int, PHAsset?, Error?) -> Void
    ) async {
        let recordManager = ConversionRecordManager.shared
        let albumManager = AlbumManager.shared
        let converter = LiveToMotionJPEGConverter.shared
        
        // 获取已转换的记录
        let convertedIdentifiers = recordManager.getAllConvertedIdentifiers()
        
        // 过滤掉已转换的 asset
        let assetsToConvert = assets.filter { asset in
            !convertedIdentifiers.contains(asset.localIdentifier)
        }
        
        let totalCount = assetsToConvert.count
        var convertedCount = 0
        var failedCount = 0
        
        // 通知总数
        progressHandler(0, 0, totalCount, nil, nil)
        
        // 获取或创建相册
        guard let album = try? await albumManager.getOrCreateAlbum() else {
            progressHandler(0, 0, totalCount, nil, NSError(
                domain: "BatchConverterError",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "无法创建或获取相册"]
            ))
            return
        }
        
        // 顺序转换，一个接一个
        for asset in assetsToConvert {
            // 检查是否暂停
            while await pauseState.checkPaused() {
                try? await Task.sleep(nanoseconds: 100_000_000) // 等待 0.1 秒
            }
            
            // 转换单个 asset
            let result = await convertSingleAsset(
                asset: asset,
                converter: converter,
                albumManager: albumManager,
                album: album,
                recordManager: recordManager
            )
            
            // 更新统计
            if result.0 {
                convertedCount += 1
                // 更新进度（成功时传递 nil asset）
                progressHandler(convertedCount, failedCount, totalCount, nil, nil)
            } else {
                failedCount += 1
                // 更新进度（失败时传递失败的 asset）
                progressHandler(convertedCount, failedCount, totalCount, asset, result.1)
            }
        }
    }
    
    // 转换单个 asset
    private func convertSingleAsset(
        asset: PHAsset,
        converter: LiveToMotionJPEGConverter,
        albumManager: AlbumManager,
        album: PHAssetCollection,
        recordManager: ConversionRecordManager
    ) async -> (Bool, Error?) {
        // 检查是否暂停
        while await pauseState.checkPaused() {
            try? await Task.sleep(nanoseconds: 100_000_000) // 等待 0.1 秒
        }
        
        do {
            // 转换 Live Photo 到 Motion JPEG
            let outputURL = try await converter.convert(from: asset)
            
            defer {
                // 清理临时文件
                try? FileManager.default.removeItem(at: outputURL)
            }
            
            // 再次检查是否暂停
            while await pauseState.checkPaused() {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            // 保存到相册
            try await albumManager.saveToAlbum(fileURL: outputURL, album: album)
            
            // 标记为已转换
            recordManager.markAsConverted(localIdentifier: asset.localIdentifier)
            
            return (true, nil)
        } catch {
            print("转换失败 \(asset.localIdentifier): \(error.localizedDescription)")
            return (false, error)
        }
    }
    
    // 单个转换（用于测试或单独使用）
    func convertSingle(asset: PHAsset) async throws -> URL {
        let converter = LiveToMotionJPEGConverter.shared
        return try await converter.convert(from: asset)
    }
}

