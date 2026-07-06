import Foundation
import Photos
import SwiftUI

class BatchConversionManager: ObservableObject {
    static let shared = BatchConversionManager()
    private init() {}
    
    private let albumName = "MoLive 转换"
    private let maxConcurrentTasks = 3 // 限制并发数为 3
    
    func fetchLivePhotos(after date: Date? = nil, state: ConversionState) {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        
        var predicateFormat = "(mediaSubtype & %d) != 0"
        var args: [Any] = [PHAssetMediaSubtype.photoLive.rawValue]
        
        if let date = date {
            predicateFormat += " AND creationDate >= %@"
            args.append(date as NSDate)
        }
        
        options.predicate = NSPredicate(format: predicateFormat, argumentArray: args)
        
        let fetchResult = PHAsset.fetchAssets(with: options)
        let convertedIDs = state.getConvertedIDs()
        
        var tasks: [ConversionState.BatchTask] = []
        var skippedCount = 0
        
        fetchResult.enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            if convertedIDs.contains(id) {
                skippedCount += 1
            } else {
                tasks.append(ConversionState.BatchTask(id: id, asset: asset, status: .pending))
            }
        }
        
        DispatchQueue.main.async {
            state.batchAssets = tasks
            state.skippedCount = skippedCount
            state.totalFoundCount = fetchResult.count
            state.successCount = 0
            state.failedCount = 0
        }
    }
    
    func startBatchConversion(state: ConversionState) async {
        let pendingIndices = state.batchAssets.indices.filter { 
            state.batchAssets[$0].status == .pending || state.batchAssets[$0].status == .failed 
        }
        
        guard !pendingIndices.isEmpty else { return }
        
        let album = try? await getOrCreateAlbum()
        let totalToConvert = pendingIndices.count
        var completedInThisSession = 0
        
        await withTaskGroup(of: (Int, Result<URL, Error>).self) { group in
            var currentIndex = 0
            
            while currentIndex < maxConcurrentTasks && currentIndex < pendingIndices.count {
                let taskIndex = pendingIndices[currentIndex]
                let asset = state.batchAssets[taskIndex].asset
                group.addTask {
                    await self.processSingleAsset(index: taskIndex, asset: asset, album: album)
                }
                currentIndex += 1
            }
            
            for await (index, result) in group {
                completedInThisSession += 1
                let currentProgress = Double(completedInThisSession) / Double(totalToConvert)
                
                await MainActor.run {
                    self.handleResult(state: state, index: index, result: result, progress: currentProgress)
                }
                
                // 补充下一个任务
                if currentIndex < pendingIndices.count {
                    let nextTaskIndex = pendingIndices[currentIndex]
                    let nextAsset = state.batchAssets[nextTaskIndex].asset
                    group.addTask {
                        await self.processSingleAsset(index: nextTaskIndex, asset: nextAsset, album: album)
                    }
                    currentIndex += 1
                }
            }
        }
    }
    
    private func processSingleAsset(index: Int, asset: PHAsset, album: PHAssetCollection?) async -> (Int, Result<URL, Error>) {
        var tempDirToCleanup: URL?
        do {
            let livePhoto = try await self.requestLivePhoto(for: asset)
            let url = try await Converter.shared.convertLivePhotoToMotionJPEG(from: livePhoto)
            // 记录临时目录路径，以便后续清理
            tempDirToCleanup = url.deletingLastPathComponent()
            
            try await self.saveToAlbum(url: url, album: album)
            
            // 优化：保存成功后立即删除临时文件
            if let dir = tempDirToCleanup {
                try? FileManager.default.removeItem(at: dir)
            }
            
            return (index, .success(url))
        } catch {
            // 出错时也要尝试清理
            if let dir = tempDirToCleanup {
                try? FileManager.default.removeItem(at: dir)
            }
            return (index, .failure(error))
        }
    }
    
    @MainActor
    private func handleResult(state: ConversionState, index: Int, result: Result<URL, Error>, progress: Double) {
        switch result {
        case .success(_):
            state.batchAssets[index].status = .success
            state.successCount += 1
            state.saveConvertedID(state.batchAssets[index].id)
        case .failure(let error):
            state.batchAssets[index].status = .failed
            state.batchAssets[index].error = error.localizedDescription
            state.failedCount += 1
        }
        
        if abs(state.conversionProgress - progress) > 0.01 || progress >= 1.0 {
            state.conversionProgress = progress
        }
    }
    
    private func getOrCreateAlbum() async throws -> PHAssetCollection {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", albumName)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        
        if let existingCollection = collections.firstObject {
            return existingCollection
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            var placeholder: PHObjectPlaceholder?
            PHPhotoLibrary.shared().performChanges({
                let createRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: self.albumName)
                placeholder = createRequest.placeholderForCreatedAssetCollection
            }) { success, error in
                if success, let placeholder = placeholder {
                    let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholder.localIdentifier], options: nil)
                    if let collection = collections.firstObject {
                        continuation.resume(returning: collection)
                    } else {
                        continuation.resume(throwing: ConversionError.conversionFailed)
                    }
                } else {
                    continuation.resume(throwing: error ?? ConversionError.conversionFailed)
                }
            }
        }
    }
    
    private func requestLivePhoto(for asset: PHAsset) async throws -> PHLivePhoto {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHLivePhotoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            
            PHImageManager.default().requestLivePhoto(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: options) { livePhoto, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let livePhoto = livePhoto {
                    continuation.resume(returning: livePhoto)
                } else if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                    continuation.resume(throwing: ConversionError.conversionFailed)
                }
            }
        }
    }
    
    private func saveToAlbum(url: URL, album: PHAssetCollection?) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let assetRequest = PHAssetCreationRequest.forAsset()
            assetRequest.addResource(with: .photo, fileURL: url, options: nil)
            
            if let album = album, let assetPlaceholder = assetRequest.placeholderForCreatedAsset {
                let albumRequest = PHAssetCollectionChangeRequest(for: album)
                albumRequest?.addAssets([assetPlaceholder] as NSArray)
            }
        }
    }
}
