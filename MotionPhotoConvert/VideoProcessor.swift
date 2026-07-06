import Foundation
import AVFoundation
import Photos

extension Converter {
    func processVideo(from data: Data, to outputURL: URL) async throws -> CMTime {
        print("开始处理视频数据...")
        
        // 创建临时文件来存储原始视频数据
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_\(UUID().uuidString).mov")
        print("创建临时视频文件：\(tempURL.path)")
        
        do {
            try data.write(to: tempURL)
            print("成功写入临时视频数据，大小：\(data.count) 字节")
            
            // 创建AVAsset
            let asset = AVURLAsset(url: tempURL)
            print("创建AVAsset成功")
            
            // 获取视频时长
            let duration = try await asset.load(.duration)
            print("视频时长：\(CMTimeGetSeconds(duration)) 秒")
            
            // 创建导出会话
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                print("错误：无法创建导出会话")
                throw ConversionError.videoCreationFailed
            }
            print("创建导出会话成功")
            
            // 设置导出参数
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mov
            exportSession.shouldOptimizeForNetworkUse = true
            
            // 设置时间范围
            let timeRange = CMTimeRange(start: .zero, duration: duration)
            exportSession.timeRange = timeRange
            
            print("开始导出视频...")
            // 执行导出
            try await exportSession.export(to: outputURL, as: .mov)
            print("视频导出成功")
            
            // 验证输出文件
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                print("错误：输出视频文件不存在")
                throw ConversionError.videoCreationFailed
            }
            
            let outputFileSize = try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? UInt64 ?? 0
            print("输出视频文件大小：\(outputFileSize) 字节")
            
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempURL)
            print("清理临时文件成功")
            
            return duration
            
        } catch {
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempURL)
            print("视频处理失败：\(error.localizedDescription)")
            throw error
        }
    }
    
    func processVideoForMotionJPEG(from url: URL) async throws -> (data: Data, stillImageTime: CMTime) {
        print("开始处理视频数据用于 Motion JPEG...")
        
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let stillImageTime = try await readStillImageTime(from: asset) ?? Self.defaultStillImageTime(for: duration)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.invalidInput
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let (renderSize, renderTransform) = Self.normalizedVideoGeometry(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        
        // 创建临时输出路径
        let tempOutputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("temp_video_\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        
        // 创建导出会话
        // Passthrough 只保留旋转矩阵，部分 Android 相册会忽略它。
        // 这里通过 videoComposition 将方向真正烘焙进视频帧。
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ConversionError.videoCreationFailed
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(nominalFrameRate.rounded(), 30)))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(renderTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        // 设置导出参数
        exportSession.outputURL = tempOutputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.timeRange = CMTimeRange(start: .zero, duration: duration)
        exportSession.videoComposition = videoComposition
        
        print("开始转码视频...")
        // 执行导出
        try await exportSession.export(to: tempOutputURL, as: .mp4)
        print("视频转码成功")
        
        // 读取转码后的视频数据
        let videoData = try Data(contentsOf: tempOutputURL)
        print("视频转码完成，大小：\(videoData.count) 字节")
        
        // 清理临时文件
        try? FileManager.default.removeItem(at: tempOutputURL)
        
        return (videoData, stillImageTime)
    }

    /// 读取 Apple Live Photo 配对视频中的展示帧时间。
    /// metadata item 的值是 0，真正的时间位于 timed metadata group 的 timeRange.start。
    private func readStillImageTime(from asset: AVAsset) async throws -> CMTime? {
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        for track in metadataTracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { continue }

            while let group = adaptor.nextTimedMetadataGroup() {
                let containsStillImageMarker = group.items.contains { item in
                    item.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" ||
                    (item.key as? String) == "com.apple.quicktime.still-image-time"
                }
                if containsStillImageMarker {
                    return group.timeRange.start
                }
            }
        }
        return nil
    }

    static func defaultStillImageTime(for duration: CMTime) -> CMTime {
        guard duration.isNumeric, duration.seconds > 0 else { return .zero }
        return CMTimeMultiplyByFloat64(duration, multiplier: 0.5)
    }

    static func presentationTimestampMicroseconds(_ time: CMTime, duration: CMTime) -> Int64 {
        guard time.isNumeric, duration.isNumeric, duration.seconds > 0 else { return 0 }
        let clampedSeconds = min(max(time.seconds, 0), duration.seconds)
        return Int64((clampedSeconds * 1_000_000).rounded())
    }

    /// 计算旋转后的显示尺寸，并将画面平移到以 (0, 0) 为原点的正坐标区域。
    /// 使用 bounding box 而不是枚举 0/90/180/270 度，可同时处理镜像和非标准矩阵。
    static func normalizedVideoGeometry(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> (renderSize: CGSize, transform: CGAffineTransform) {
        let sourceRect = CGRect(origin: .zero, size: naturalSize)
        let transformedRect = sourceRect.applying(preferredTransform)
        let renderSize = CGSize(
            width: abs(transformedRect.width).rounded(.up),
            height: abs(transformedRect.height).rounded(.up)
        )
        let translation = CGAffineTransform(
            translationX: -transformedRect.minX,
            y: -transformedRect.minY
        )
        return (renderSize, preferredTransform.concatenating(translation))
    }
    
    func getPairedVideoURL(for photoURL: URL) async throws -> URL {
        // 获取照片文件名（不包含扩展名）
        let photoFileName = photoURL.deletingPathExtension().lastPathComponent
        
        // 获取照片所在目录
        let directory = photoURL.deletingLastPathComponent()
        
        // 查找匹配的视频文件
        let videoExtensions = ["mov", "mp4"]
        let fileManager = FileManager.default
        
        let directoryContents = try fileManager.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])
        
        for url in directoryContents {
            let fileName = url.deletingPathExtension().lastPathComponent
            let fileExtension = url.pathExtension.lowercased()
            
            if fileName == photoFileName && videoExtensions.contains(fileExtension) {
                return url
            }
        }
        
        throw ConversionError.invalidInput
    }
}
