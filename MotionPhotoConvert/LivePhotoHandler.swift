import Foundation
import Photos
import AVFoundation
import UIKit

extension Converter {
    private actor LivePhotoContinuationHandler {
        private var hasResumed = false
        
        func tryResume<T>(continuation: CheckedContinuation<T, Error>, with value: T) {
            guard !hasResumed else { return }
            hasResumed = true
            continuation.resume(returning: value)
        }
        
        func tryResumeWithError<T>(continuation: CheckedContinuation<T, Error>, error: Error) {
            guard !hasResumed else { return }
            hasResumed = true
            continuation.resume(throwing: error)
        }
    }
    
    func createLivePhoto(photoURL: URL, videoURL: URL) async throws -> PHLivePhoto {
        print("开始创建 Live Photo...")
        
        // 读取照片数据
        guard let photoData = try? Data(contentsOf: photoURL),
              let image = UIImage(data: photoData) else {
            throw ConversionError.invalidInput
        }
        
        // 创建 Live Photo
        let handler = LivePhotoContinuationHandler()
        return try await withCheckedThrowingContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: [photoURL, videoURL],
                              placeholderImage: image,
                              targetSize: image.size,
                              contentMode: .aspectFit) { [handler] livePhoto, info in
                if let livePhoto = livePhoto {
                    print("Live Photo创建成功")
                    Task {
                        await handler.tryResume(continuation: continuation, with: livePhoto)
                    }
                } else {
                    print("Live Photo创建失败")
                    Task {
                        await handler.tryResumeWithError(continuation: continuation,
                                                       error: ConversionError.conversionFailed)
                    }
                }
            }
        }
    }
    
    func saveLivePhotoToLibrary(
        photoURL: URL,
        videoURL: URL,
        stillImageTime: CMTime = .invalid
    ) async throws {
        guard await checkPhotoLibraryPermission() else {
            throw ConversionError.noPermission
        }
        
        print("开始生成 Live Photo...")
        
        // 1. 生成 Live Photo 资源
        let resources = try await generateLivePhotoResources(
            from: photoURL,
            videoURL: videoURL,
            stillImageTime: stillImageTime
        )
        defer {
            try? FileManager.default.removeItem(at: resources.pairedImage.deletingLastPathComponent())
        }
        
        // 2. 保存到相册
        print("开始保存到相册...")
        try await saveLivePhotoResources(resources)
        
        print("Live Photo保存成功")
    }
    
    private func generateLivePhotoResources(
        from photoURL: URL,
        videoURL: URL,
        stillImageTime requestedStillImageTime: CMTime
    ) async throws -> LivePhotoResources {
        // 1. 创建临时目录
        let tempDirectory = try createTempDirectory(prefix: "LivePhotoTemp")
        var completedSuccessfully = false
        defer {
            if !completedSuccessfully {
                try? FileManager.default.removeItem(at: tempDirectory)
            }
        }
        
        // 2. 生成资源标识符
        let assetIdentifier = UUID().uuidString
        
        // 3. 处理照片
        let pairedImageURL = tempDirectory.appendingPathComponent("paired_photo").appendingPathExtension("jpg")
        guard let imageDestination = CGImageDestinationCreateWithURL(pairedImageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil),
              let imageSource = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              let imageRef = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              var imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [AnyHashable: Any] else {
            throw ConversionError.conversionFailed
        }
        
        // 添加资源标识符和显示时间
        var makerApple = imageProperties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
        makerApple["17"] = assetIdentifier
        imageProperties[kCGImagePropertyMakerAppleDictionary as String] = makerApple
        CGImageDestinationAddImage(imageDestination, imageRef, imageProperties as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw ConversionError.conversionFailed
        }
        
        // 4. 处理视频
        let pairedVideoURL = tempDirectory.appendingPathComponent("paired_video").appendingPathExtension("mov")
        let videoAsset = AVURLAsset(url: videoURL)
        let duration = try await videoAsset.load(.duration)
        let stillImageTime = requestedStillImageTime.isNumeric
            ? CMTimeMinimum(CMTimeMaximum(requestedStillImageTime, .zero), duration)
            : Self.defaultStillImageTime(for: duration)
        
        // 获取视频属性
        let tracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw ConversionError.invalidInput
        }
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        
        // 创建视频写入器
        let assetWriter = try AVAssetWriter(outputURL: pairedVideoURL, fileType: .mov)
        
        // 设置视频参数
        let videoWriterInput = AVAssetWriterInput(mediaType: .video,
                                                 outputSettings: [
                                                    AVVideoCodecKey: AVVideoCodecType.h264,
                                                    AVVideoWidthKey: naturalSize.width,
                                                    AVVideoHeightKey: naturalSize.height
                                                 ])
        videoWriterInput.transform = transform
        videoWriterInput.expectsMediaDataInRealTime = false
        guard assetWriter.canAdd(videoWriterInput) else {
            throw ConversionError.videoCreationFailed
        }
        assetWriter.add(videoWriterInput)

        let videoReader = try AVAssetReader(asset: videoAsset)
        let videoReaderOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        guard videoReader.canAdd(videoReaderOutput) else {
            throw ConversionError.videoCreationFailed
        }
        videoReader.add(videoReaderOutput)

        // 保留原始音轨。旧实现只写入视频，会让反向转换的 Live Photo 静音。
        var audioPair: (input: AVAssetWriterInput, output: AVAssetReaderTrackOutput)?
        if let audioTrack = try await videoAsset.loadTracks(withMediaType: .audio).first {
            let formatDescriptions = try await audioTrack.load(.formatDescriptions)
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescriptions.first
            )
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if assetWriter.canAdd(audioInput), videoReader.canAdd(audioOutput) {
                audioInput.expectsMediaDataInRealTime = false
                assetWriter.add(audioInput)
                videoReader.add(audioOutput)
                audioPair = (audioInput, audioOutput)
            }
        }

        let (metadataInput, metadataAdaptor) = try makeStillImageMetadataAdaptor(for: assetWriter)
        
        // 添加资源标识符元数据
        let metadataItem = AVMutableMetadataItem()
        metadataItem.key = "com.apple.quicktime.content.identifier" as (NSCopying & NSObjectProtocol)
        metadataItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        metadataItem.value = assetIdentifier as (NSCopying & NSObjectProtocol)
        metadataItem.dataType = "com.apple.metadata.datatype.UTF-8"
        assetWriter.metadata = [metadataItem]
        
        // 开始写入视频
        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? ConversionError.videoCreationFailed
        }
        assetWriter.startSession(atSourceTime: .zero)

        let stillImageItem = AVMutableMetadataItem()
        stillImageItem.identifier = AVMetadataIdentifier(
            rawValue: "mdta/com.apple.quicktime.still-image-time"
        )
        stillImageItem.dataType = "com.apple.metadata.datatype.int8"
        stillImageItem.value = NSNumber(value: Int8(0))
        let metadataDuration = CMTime(value: 1, timescale: 30)
        let metadataGroup = AVTimedMetadataGroup(
            items: [stillImageItem],
            timeRange: CMTimeRange(start: stillImageTime, duration: metadataDuration)
        )
        guard metadataAdaptor.append(metadataGroup) else {
            throw assetWriter.error ?? ConversionError.videoCreationFailed
        }
        metadataInput.markAsFinished()

        guard videoReader.startReading() else {
            throw videoReader.error ?? ConversionError.videoCreationFailed
        }

        async let videoWrite: Void = appendSamples(
            from: videoReaderOutput,
            to: videoWriterInput,
            queueLabel: "com.molive.videowriting"
        )
        if let audioPair {
            async let audioWrite: Void = appendSamples(
                from: audioPair.output,
                to: audioPair.input,
                queueLabel: "com.molive.audiowriting"
            )
            _ = try await (videoWrite, audioWrite)
        } else {
            try await videoWrite
        }

        await assetWriter.finishWriting()
        guard assetWriter.status == .completed else {
            throw assetWriter.error ?? ConversionError.videoCreationFailed
        }
        
        completedSuccessfully = true
        return (pairedImageURL, pairedVideoURL)
    }

    private func makeStillImageMetadataAdaptor(
        for writer: AVAssetWriter
    ) throws -> (AVAssetWriterInput, AVAssetWriterInputMetadataAdaptor) {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                "com.apple.metadata.datatype.int8"
        ]
        var formatDescription: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw ConversionError.videoCreationFailed
        }

        let input = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: formatDescription
        )
        guard writer.canAdd(input) else {
            throw ConversionError.videoCreationFailed
        }
        writer.add(input)
        return (input, AVAssetWriterInputMetadataAdaptor(assetWriterInput: input))
    }

    private func appendSamples(
        from output: AVAssetReaderTrackOutput,
        to input: AVAssetWriterInput,
        queueLabel: String
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: queueLabel)
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sampleBuffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    guard input.append(sampleBuffer) else {
                        input.markAsFinished()
                        continuation.resume(throwing: ConversionError.videoCreationFailed)
                        return
                    }
                }
            }
        }
    }
    
    private func saveLivePhotoResources(_ resources: LivePhotoResources) async throws {
        try PHPhotoLibrary.shared().performChangesAndWait {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: .photo, fileURL: resources.pairedImage, options: options)
            request.addResource(with: .pairedVideo, fileURL: resources.pairedVideo, options: options)
        }
    }
    
    func getLivePhotoResources(from livePhoto: PHLivePhoto) async throws -> (photoURL: URL, videoURL: URL) {
        print("开始获取 Live Photo 资源...")
        return try await writeLivePhotoResources(PHAssetResource.assetResources(for: livePhoto))
    }

    func getLivePhotoResources(from asset: PHAsset) async throws -> (photoURL: URL, videoURL: URL) {
        try await writeLivePhotoResources(PHAssetResource.assetResources(for: asset))
    }

    private func writeLivePhotoResources(
        _ resources: [PHAssetResource]
    ) async throws -> (photoURL: URL, videoURL: URL) {
        let tempDirectory = try createTempDirectory(prefix: "LivePhotoTemp")
        let photoURL = tempDirectory.appendingPathComponent("photo.jpg")
        let videoURL = tempDirectory.appendingPathComponent("video.mov")

        guard let photoResource = preferredResource(in: resources, types: [.photo, .fullSizePhoto]),
              let videoResource = preferredResource(in: resources, types: [.pairedVideo, .fullSizePairedVideo]) else {
            try? FileManager.default.removeItem(at: tempDirectory)
            throw ConversionError.invalidInput
        }

        do {
            async let photoWrite: Void = writeResource(photoResource, to: photoURL)
            async let videoWrite: Void = writeResource(videoResource, to: videoURL)
            _ = try await (photoWrite, videoWrite)
            return (photoURL, videoURL)
        } catch {
            try? FileManager.default.removeItem(at: tempDirectory)
            throw error
        }
    }

    private func preferredResource(
        in resources: [PHAssetResource],
        types: [PHAssetResourceType]
    ) -> PHAssetResource? {
        for type in types {
            if let resource = resources.first(where: { $0.type == type }) {
                return resource
            }
        }
        return nil
    }

    private func writeResource(_ resource: PHAssetResource, to targetURL: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try? FileManager.default.removeItem(at: targetURL)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: targetURL,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else if FileManager.default.fileExists(atPath: targetURL.path) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ConversionError.conversionFailed)
                }
            }
        }
    }
}
