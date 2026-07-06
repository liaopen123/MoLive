import Foundation
import Photos
import AVFoundation
import UIKit
import UniformTypeIdentifiers

extension Converter {
    func convertMotionJPEGToLivePhoto(from url: URL) async throws -> PHLivePhoto {
        print("开始转换动态照片...")
        
        // 读取文件数据
        let data = try Data(contentsOf: url)
        print("成功读取文件数据，大小：\(data.count) 字节")
        
        // 创建临时目录
        let tempDirectory = try createTempDirectory(prefix: "MotionJPEGConvert")
        let tempPhotoURL = tempDirectory.appendingPathComponent("photo").appendingPathExtension("jpg")
        let tempVideoURL = tempDirectory.appendingPathComponent("video").appendingPathExtension("mov")
        let processedVideoURL = tempDirectory.appendingPathComponent("processed_video").appendingPathExtension("mov")
        
        defer {
            // 清理临时文件
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        
        // 分离图片和视频数据
        let stillImageTime = try await separateImageAndVideo(
            from: data,
            photoURL: tempPhotoURL,
            videoURL: tempVideoURL
        )
        
        // 处理视频数据
        let videoData = try Data(contentsOf: tempVideoURL)
        _ = try await processVideo(from: videoData, to: processedVideoURL)
        
        // 创建 Live Photo
        let livePhoto = try await createLivePhoto(photoURL: tempPhotoURL, videoURL: processedVideoURL)
        
        // 保存到相册
        try await saveLivePhotoToLibrary(
            photoURL: tempPhotoURL,
            videoURL: processedVideoURL,
            stillImageTime: stillImageTime
        )
        
        return livePhoto
    }
    
    func convertLivePhotoToMotionJPEG(from livePhoto: PHLivePhoto) async throws -> URL {
        print("开始转换 Live Photo...")

        let resources = try await getLivePhotoResources(from: livePhoto)
        defer { try? FileManager.default.removeItem(at: resources.photoURL.deletingLastPathComponent()) }
        return try await convertLivePhotoResources(
            photoURL: resources.photoURL,
            videoURL: resources.videoURL
        )
    }

    func convertLivePhotoToMotionJPEG(from asset: PHAsset) async throws -> URL {
        let resources = try await getLivePhotoResources(from: asset)
        defer { try? FileManager.default.removeItem(at: resources.photoURL.deletingLastPathComponent()) }
        return try await convertLivePhotoResources(
            photoURL: resources.photoURL,
            videoURL: resources.videoURL
        )
    }

    private func convertLivePhotoResources(photoURL: URL, videoURL: URL) async throws -> URL {
        // 创建临时目录
        let tempDirectory = try createTempDirectory(prefix: "LivePhotoConvert")
        let tempJPEGURL = tempDirectory.appendingPathComponent("temp").appendingPathExtension("jpg")
        let outputURL = tempDirectory.appendingPathComponent("MVIMG_\(UUID().uuidString)_MP").appendingPathExtension("jpg")

        do {
            // 读取照片数据和属性。CGImage 不会自动应用 EXIF Orientation，
            // 因此在转成 JPEG 时将方向烘焙进像素，避免 Android 相册忽略方向标记。
            guard let imageSource = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
                  var imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
                throw ConversionError.conversionFailed
            }

            let sourceOrientation = (imageProperties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
            let sourceIsJPEG = CGImageSourceGetType(imageSource) as String? == UTType.jpeg.identifier
            if sourceIsJPEG && sourceOrientation == 1 {
                // 原图已是正向 JPEG：直接复制压缩数据，像素完全无损。
                try FileManager.default.copyItem(at: photoURL, to: tempJPEGURL)
            } else {
                guard let imageRef = createOrientationNormalizedImage(
                    from: imageSource,
                    properties: imageProperties
                ),
                let destination = CGImageDestinationCreateWithURL(
                    tempJPEGURL as CFURL,
                    UTType.jpeg.identifier as CFString,
                    1,
                    nil
                ) else {
                    throw ConversionError.conversionFailed
                }

                imageProperties[kCGImagePropertyOrientation as String] = 1
                var tiffProperties = imageProperties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
                tiffProperties[kCGImagePropertyTIFFOrientation as String] = 1
                imageProperties[kCGImagePropertyTIFFDictionary as String] = tiffProperties
                var finalProperties = imageProperties
                finalProperties[kCGImageDestinationLossyCompressionQuality as String] = 1.0

                CGImageDestinationAddImage(destination, imageRef, finalProperties as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw ConversionError.conversionFailed
                }
            }

            // 处理视频数据
            let processedVideo = try await processVideoForMotionJPEG(from: videoURL)
            let videoData = processedVideo.data
            print("视频数据大小: \(videoData.count) 字节")

            let videoDuration = try await AVURLAsset(url: videoURL).load(.duration)
            let presentationTimestampUs = Self.presentationTimestampMicroseconds(
                processedVideo.stillImageTime,
                duration: videoDuration
            )
            
            // 添加元数据
            let photoWithMetadata = try await addXiaomiMetadata(
                to: tempJPEGURL,
                offset: videoData.count,
                presentationTimestampUs: presentationTimestampUs
            )
            
            let photoData = try Data(contentsOf: photoWithMetadata, options: .mappedIfSafe)
            // Motion Photo 是“完整 JPEG + 视频”。EOI (FF D9) 必须保留，
            // 否则严格的 JPEG 解码器会将文件判定为损坏。
            guard photoData.count >= 2,
                  photoData[photoData.count - 2] == 0xFF,
                  photoData[photoData.count - 1] == 0xD9 else {
                throw ConversionError.conversionFailed
            }

            // 流式生成最终文件，避免再创建一份“JPEG + 整段视频”的大 Data。
            try FileManager.default.copyItem(at: photoWithMetadata, to: outputURL)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }
            try outputHandle.seekToEnd()
            try outputHandle.write(contentsOf: videoData)

            let mappedOutput = try Data(contentsOf: outputURL, options: .mappedIfSafe)
            let validation = try await Self.validateMotionPhoto(data: mappedOutput)
            print("验证通过：\(validation.summary)")
            print("最终文件大小: \(mappedOutput.count) 字节")
            
            // 清理中间临时文件
            try? FileManager.default.removeItem(at: tempJPEGURL)
            try? FileManager.default.removeItem(at: photoWithMetadata)
            
            return outputURL
        } catch {
            // 如果处理过程中出错，清理所有临时文件
            try? FileManager.default.removeItem(at: tempDirectory)
            throw error
        }
    }
    
    private func separateImageAndVideo(from data: Data, photoURL: URL, videoURL: URL) async throws -> CMTime {
        print("开始分离图片和视频数据...")
        
        let components = try Self.motionPhotoComponents(from: data)
        let imageData = components.jpegData
        
        // 验证提取的图片数据
        if let image = UIImage(data: imageData) {
            print("验证图片成功，尺寸：\(image.size)")
        } else {
            // 如果直接创建失败，尝试使用CGImageSource
            let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil)
            if let imageSource = imageSource,
               let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                let image = UIImage(cgImage: cgImage)
                print("通过CGImageSource验证图片成功，尺寸：\(image.size)")
            } else {
                throw ConversionError.invalidInput
            }
        }
        
        // 保存分离的数据
        try imageData.write(to: photoURL, options: [.atomic])
        try components.videoData.write(to: videoURL, options: [.atomic])
        let presentationTime = Self.motionPhotoPresentationTime(fromJPEGData: imageData) ?? .invalid
        let videoAsset = AVURLAsset(url: videoURL)
        let duration = try await videoAsset.load(.duration)
        guard duration.isNumeric,
              duration.seconds > 0,
              !(try await videoAsset.loadTracks(withMediaType: .video)).isEmpty else {
            throw ConversionError.invalidInput
        }
        if presentationTime.isNumeric,
           (presentationTime < .zero || presentationTime > duration) {
            throw ConversionError.xmpParsingError("展示帧时间超出视频范围")
        }
        return presentationTime
    }

    struct MotionPhotoComponents {
        let jpegData: Data
        let videoData: Data
        let videoStartOffset: Int
        let usedXMPVideoOffset: Bool
        let repairedMissingJPEGEnd: Bool
    }

    struct MotionPhotoValidationReport {
        let jpegByteCount: Int
        let videoByteCount: Int
        let pixelSize: CGSize
        let duration: TimeInterval
        let hasAudio: Bool
        let presentationTimestampUs: Int64?
        let usesContainerDirectory: Bool
        let usesLegacyMicroVideo: Bool

        var summary: String {
            let audio = hasAudio ? "含音轨" : "无音轨"
            return "JPEG \(jpegByteCount) B，视频 \(videoByteCount) B，\(duration) 秒，\(audio)"
        }
    }

    static func validateMotionPhoto(data: Data) async throws -> MotionPhotoValidationReport {
        let components = try motionPhotoComponents(from: data)
        guard let imageSource = CGImageSourceCreateWithData(components.jpegData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil else {
            throw ConversionError.invalidInput
        }
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { throw ConversionError.invalidInput }

        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoLiveValidation_\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try components.videoData.write(to: videoURL, options: .atomic)

        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard duration.isNumeric, duration.seconds > 0, !videoTracks.isEmpty else {
            throw ConversionError.invalidInput
        }

        let presentationTime = motionPhotoPresentationTime(fromJPEGData: components.jpegData)
        if let presentationTime,
           (presentationTime < .zero || presentationTime > duration) {
            throw ConversionError.xmpParsingError("展示帧时间超出视频范围")
        }

        return MotionPhotoValidationReport(
            jpegByteCount: components.jpegData.count,
            videoByteCount: components.videoData.count,
            pixelSize: CGSize(width: width, height: height),
            duration: duration.seconds,
            hasAudio: !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
            presentationTimestampUs: presentationTime.map {
                presentationTimestampMicroseconds($0, duration: duration)
            },
            usesContainerDirectory: containerMotionPhotoLength(from: components.jpegData) != nil,
            usesLegacyMicroVideo: microVideoOffset(from: components.jpegData) != nil
        )
    }

    /// 优先使用 XMP 中“从文件尾部计算”的视频长度。
    /// 旧文件缺少 offset 时，才从完整 JPEG EOI 之后扫描 ISO BMFF ftyp box。
    static func motionPhotoComponents(from data: Data) throws -> MotionPhotoComponents {
        let containerLength = containerMotionPhotoLength(from: data)
        let legacyLength = microVideoOffset(from: data)
        if let containerLength, let legacyLength, containerLength != legacyLength {
            throw ConversionError.xmpParsingError("新旧 XMP 中的视频长度不一致")
        }

        if let videoLength = containerLength ?? legacyLength,
           videoLength > 0,
           videoLength < data.count {
            let videoStart = data.count - videoLength
            guard isISOBaseMediaFile(data, at: videoStart) else {
                throw ConversionError.xmpParsingError("视频 offset 与文件结构不匹配")
            }
            var repairedMissingJPEGEnd = false
            let jpegData: Data
            if let jpegEnd = jpegEndOffset(in: data), jpegEnd <= videoStart {
                jpegData = data.subdata(in: 0..<jpegEnd)
            } else {
                // MoLive 旧版曾在拼接前删除 FF D9。XMP offset 可以精确界定图片与视频，
                // 因此可安全地为这类存量文件恢复 JPEG 结束标记。
                var candidate = data.subdata(in: 0..<videoStart)
                guard candidate.count >= 2, candidate[0] == 0xFF, candidate[1] == 0xD8 else {
                    throw ConversionError.invalidInput
                }
                candidate.append(contentsOf: [0xFF, 0xD9])
                guard CGImageSourceCreateWithData(candidate as CFData, nil) != nil else {
                    throw ConversionError.invalidInput
                }
                jpegData = candidate
                repairedMissingJPEGEnd = true
            }
            return MotionPhotoComponents(
                jpegData: jpegData,
                videoData: data.subdata(in: videoStart..<data.count),
                videoStartOffset: videoStart,
                usedXMPVideoOffset: true,
                repairedMissingJPEGEnd: repairedMissingJPEGEnd
            )
        }

        guard let jpegEnd = jpegEndOffset(in: data) else {
            throw ConversionError.invalidInput
        }
        guard let videoStart = firstISOBaseMediaOffset(in: data, startingAt: jpegEnd) else {
            throw ConversionError.invalidInput
        }
        return MotionPhotoComponents(
            jpegData: data.subdata(in: 0..<jpegEnd),
            videoData: data.subdata(in: videoStart..<data.count),
            videoStartOffset: videoStart,
            usedXMPVideoOffset: false,
            repairedMissingJPEGEnd: false
        )
    }

    static func microVideoOffset(from data: Data) -> Int? {
        let text = String(decoding: data, as: UTF8.self)
        let patterns = [
            #"<GCamera:MicroVideoOffset>\s*(\d+)\s*</GCamera:MicroVideoOffset>"#,
            #"GCamera:MicroVideoOffset=[\"'](\d+)[\"']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let valueRange = Range(match.range(at: 1), in: text),
                  let value = Int(text[valueRange]) else { continue }
            return value
        }
        return nil
    }

    static func containerMotionPhotoLength(from data: Data) -> Int? {
        let text = String(decoding: data, as: UTF8.self)
        guard let itemRegex = try? NSRegularExpression(
            pattern: #"<(?:Container|GContainer):Item\b[^>]*>"#
        ) else { return nil }
        let fullRange = NSRange(text.startIndex..., in: text)

        for match in itemRegex.matches(in: text, range: fullRange) {
            guard let tagRange = Range(match.range, in: text) else { continue }
            let tag = String(text[tagRange])
            guard tag.range(
                of: #"Item:Semantic\s*=\s*[\"']MotionPhoto[\"']"#,
                options: .regularExpression
            ) != nil,
            let lengthRegex = try? NSRegularExpression(
                pattern: #"Item:Length\s*=\s*[\"'](\d+)[\"']"#
            ),
            let lengthMatch = lengthRegex.firstMatch(
                in: tag,
                range: NSRange(tag.startIndex..., in: tag)
            ),
            let lengthRange = Range(lengthMatch.range(at: 1), in: tag),
            let length = Int(tag[lengthRange]) else { continue }
            return length
        }
        return nil
    }

    private static func jpegEndOffset(in data: Data) -> Int? {
        guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var index = 2
        var insideScanData = false

        while index + 1 < data.count {
            guard data[index] == 0xFF else {
                index += 1
                continue
            }
            var markerIndex = index + 1
            while markerIndex < data.count, data[markerIndex] == 0xFF { markerIndex += 1 }
            guard markerIndex < data.count else { return nil }
            let marker = data[markerIndex]

            if marker == 0xD9 { return markerIndex + 1 }
            if insideScanData {
                if marker == 0x00 || (0xD0...0xD7).contains(marker) {
                    index = markerIndex + 1
                    continue
                }
                // 渐进式 JPEG 可以在多个 scan 之间出现新的段。
                insideScanData = false
            }

            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                index = markerIndex + 1
                continue
            }
            guard markerIndex + 2 < data.count else { return nil }
            let length = Int(data[markerIndex + 1]) << 8 | Int(data[markerIndex + 2])
            guard length >= 2, markerIndex + length < data.count else { return nil }
            index = markerIndex + 1 + length
            if marker == 0xDA { insideScanData = true }
        }
        return nil
    }

    private static func firstISOBaseMediaOffset(in data: Data, startingAt offset: Int) -> Int? {
        guard offset < data.count else { return nil }
        for candidate in offset..<max(offset, data.count - 7) {
            if isISOBaseMediaFile(data, at: candidate) { return candidate }
        }
        return nil
    }

    private static func isISOBaseMediaFile(_ data: Data, at offset: Int) -> Bool {
        guard offset >= 0, offset + 12 <= data.count else { return false }
        let boxSize = Int(data[offset]) << 24 |
            Int(data[offset + 1]) << 16 |
            Int(data[offset + 2]) << 8 |
            Int(data[offset + 3])
        let hasFtyp = data[offset + 4] == 0x66 && data[offset + 5] == 0x74 &&
            data[offset + 6] == 0x79 && data[offset + 7] == 0x70
        return hasFtyp && (boxSize == 0 || (boxSize >= 12 && offset + boxSize <= data.count))
    }

    static func motionPhotoPresentationTime(fromJPEGData data: Data) -> CMTime? {
        let text = String(decoding: data, as: UTF8.self)
        let patterns = [
            #"<(?:GCamera|Camera):MotionPhotoPresentationTimestampUs>\s*(\d+)\s*</(?:GCamera|Camera):MotionPhotoPresentationTimestampUs>"#,
            #"(?:GCamera|Camera):MotionPhotoPresentationTimestampUs=[\"'](\d+)[\"']"#,
            #"<GCamera:MicroVideoPresentationTimestampUs>\s*(\d+)\s*</GCamera:MicroVideoPresentationTimestampUs>"#,
            #"GCamera:MicroVideoPresentationTimestampUs=[\"'](\d+)[\"']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                  ),
                  let valueRange = Range(match.range(at: 1), in: text),
                  let microseconds = Int64(text[valueRange]) else {
                continue
            }
            return CMTime(value: microseconds, timescale: 1_000_000)
        }
        return nil
    }
    
    private func addXiaomiMetadata(
        to url: URL,
        offset: Int,
        presentationTimestampUs: Int64
    ) async throws -> URL {
        // 1. 读取原始数据并提取 iPhone 基础元数据
        let imageData = try Data(contentsOf: url)
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil,
              let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            throw ConversionError.conversionFailed
        }

        let tiffDict = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let make = tiffDict[kCGImagePropertyTIFFMake as String] as? String ?? "Apple"
        let model = tiffDict[kCGImagePropertyTIFFModel as String] as? String ?? "iPhone"
        let software = tiffDict[kCGImagePropertyTIFFSoftware as String] as? String ?? "iOS"
        let dateTime = tiffDict[kCGImagePropertyTIFFDateTime as String] as? String ?? ""
        // 图像在上一步已经将方向烘焙进像素，输出文件必须统一为 top-left。
        let orientation: UInt16 = 1
        
        // 提取 GPS 信息
        let gpsDict = metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]

        // 2. 直接复用已经完成方向归一化的 JPEG 像素数据。
        // 旧实现会在这里再解码/编码一次，既慢又会产生第二次有损压缩。
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent("MVIMG_\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        let pureImageData = try Self.removingExistingExifAndXMP(from: imageData)

        // 3. 构建 EXIF 段 (APP1)
        var exifData = Data()
        // TIFF 头部 (8 bytes)
        exifData.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08])
        
        // 准备字符串和 GPS 数据
        let makeData = (make + "\0").data(using: .utf8)!
        let modelData = (model + "\0").data(using: .utf8)!
        let softwareData = (software + "\0").data(using: .utf8)!
        let dateTimeData = (dateTime.isEmpty ? "" : dateTime + "\0").data(using: .utf8)!
        
        // IFD0 结构计算
        let hasGPS = !gpsDict.isEmpty
        let ifd0EntriesCount: UInt16 = 6 + (hasGPS ? 1 : 0)
        let ifd0Size = 2 + (Int(ifd0EntriesCount) * 12) + 4
        var currentOffset = UInt32(8 + ifd0Size)
        
        let makeOff = currentOffset; currentOffset += UInt32(makeData.count)
        let modelOff = currentOffset; currentOffset += UInt32(modelData.count)
        let softwareOff = currentOffset; currentOffset += UInt32(softwareData.count)
        let dateTimeOff = dateTimeData.isEmpty ? 0 : currentOffset
        if !dateTimeData.isEmpty { currentOffset += UInt32(dateTimeData.count) }
        
        let gpsIFDOff = hasGPS ? currentOffset : 0
        
        // 构建 GPS 数据块 (如果存在)
        var gpsContentData = Data()
        if hasGPS {
            var entries: [(tag: UInt16, type: UInt16, count: UInt32, data: Data)] = []
            
            // GPSVersionID
            entries.append((0x0000, 1, 4, Data([0x02, 0x03, 0x00, 0x00])))
            
            if let ref = gpsDict[kCGImagePropertyGPSLatitudeRef as String] as? String {
                entries.append((0x0001, 2, 2, (ref + "\0").data(using: .ascii)!))
            }
            if let val = gpsDict[kCGImagePropertyGPSLatitude as String] as? Double {
                entries.append((0x0002, 5, 3, packGPSCoordinate(val)))
            }
            if let ref = gpsDict[kCGImagePropertyGPSLongitudeRef as String] as? String {
                entries.append((0x0003, 2, 2, (ref + "\0").data(using: .ascii)!))
            }
            if let val = gpsDict[kCGImagePropertyGPSLongitude as String] as? Double {
                entries.append((0x0004, 5, 3, packGPSCoordinate(val)))
            }
            if let ref = gpsDict[kCGImagePropertyGPSAltitudeRef as String] as? UInt8 {
                entries.append((0x0005, 1, 1, Data([ref, 0, 0, 0])))
            }
            if let val = gpsDict[kCGImagePropertyGPSAltitude as String] as? Double {
                entries.append((0x0006, 5, 1, packRational(val)))
            }

            gpsContentData.append(contentsOf: packUInt16(UInt16(entries.count)))
            let gpsEntriesSize = entries.count * 12
            // 关键：偏移量必须相对于 TIFF 头部 (MM)
            var gpsDataOffset = gpsIFDOff + UInt32(2 + gpsEntriesSize + 4)
            
            var entryData = Data()
            var valueData = Data()
            
            for entry in entries {
                entryData.append(contentsOf: packUInt16(entry.tag))
                entryData.append(contentsOf: packUInt16(entry.type))
                entryData.append(contentsOf: packUInt32(entry.count))
                
                if entry.data.count <= 4 {
                    var padded = entry.data
                    while padded.count < 4 { padded.append(0) }
                    entryData.append(padded)
                } else {
                    entryData.append(contentsOf: packUInt32(gpsDataOffset))
                    valueData.append(entry.data)
                    gpsDataOffset += UInt32(entry.data.count)
                }
            }
            gpsContentData.append(entryData)
            gpsContentData.append(contentsOf: [0, 0, 0, 0]) // Next GPS IFD
            gpsContentData.append(valueData)
            
            currentOffset += UInt32(gpsContentData.count)
        }
        
        let exifIFDOff = currentOffset
        
        // 写入 IFD0
        exifData.append(contentsOf: packUInt16(ifd0EntriesCount))
        exifData.append(contentsOf: buildExifEntry(tag: 0x010F, type: 2, count: UInt32(makeData.count), value: makeOff))
        exifData.append(contentsOf: buildExifEntry(tag: 0x0110, type: 2, count: UInt32(modelData.count), value: modelOff))
        exifData.append(contentsOf: buildExifEntry(tag: 0x0131, type: 2, count: UInt32(softwareData.count), value: softwareOff))
        exifData.append(contentsOf: buildExifEntry(tag: 0x0112, type: 3, count: 1, value: UInt32(orientation) << 16))
        exifData.append(contentsOf: buildExifEntry(tag: 0x0132, type: 2, count: UInt32(dateTimeData.count), value: dateTimeOff))
        if hasGPS {
            exifData.append(contentsOf: buildExifEntry(tag: 0x8825, type: 4, count: 1, value: gpsIFDOff)) // GPS IFD Offset
        }
        exifData.append(contentsOf: buildExifEntry(tag: 0x8769, type: 4, count: 1, value: exifIFDOff)) // ExifOffset
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Next IFD offset
        
        // 写入字符串和 GPS 数据
        exifData.append(makeData); exifData.append(modelData); exifData.append(softwareData)
        if !dateTimeData.isEmpty { exifData.append(dateTimeData) }
        if hasGPS { exifData.append(gpsContentData) }
        
        // 写入 ExifSubIFD (包含小米 0x8897)
        exifData.append(contentsOf: packUInt16(1)) // 1 entry
        exifData.append(contentsOf: buildExifEntry(tag: 0x8897, type: 1, count: 1, value: 0x01000000)) // BYTE value 1
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        
        // 封装为 APP1 段
        var exifApp1 = Data([0xFF, 0xE1])
        let exifLen = UInt16(exifData.count + 8) // +2(len) +6(header)
        exifApp1.append(contentsOf: packUInt16(exifLen))
        exifApp1.append(contentsOf: "Exif\0\0".data(using: .ascii)!)
        exifApp1.append(exifData)

        // 4. 构建 XMP 段 (APP1)
        let xmpString = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.0">
           <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                    xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"
                    xmlns:Container="http://ns.google.com/photos/1.0/container/"
                    xmlns:Item="http://ns.google.com/photos/1.0/container/item/">
                 <GCamera:MotionPhoto>1</GCamera:MotionPhoto>
                 <GCamera:MotionPhotoVersion>1</GCamera:MotionPhotoVersion>
                 <GCamera:MotionPhotoPresentationTimestampUs>\(presentationTimestampUs)</GCamera:MotionPhotoPresentationTimestampUs>
                 <GCamera:MicroVideo>1</GCamera:MicroVideo>
                 <GCamera:MicroVideoVersion>1</GCamera:MicroVideoVersion>
                 <GCamera:MicroVideoOffset>\(offset)</GCamera:MicroVideoOffset>
                 <GCamera:MicroVideoPresentationTimestampUs>\(presentationTimestampUs)</GCamera:MicroVideoPresentationTimestampUs>
                 <Container:Directory>
                    <rdf:Seq>
                       <rdf:li rdf:parseType="Resource">
                          <Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0" Item:Padding="0"/>
                       </rdf:li>
                       <rdf:li rdf:parseType="Resource">
                          <Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="\(offset)"/>
                       </rdf:li>
                    </rdf:Seq>
                 </Container:Directory>
              </rdf:Description>
           </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let xmpContent = xmpString.data(using: .utf8)!
        let xmpId = "http://ns.adobe.com/xap/1.0/\0".data(using: .utf8)!
        var xmpApp1 = Data([0xFF, 0xE1])
        let xmpLen = UInt16(xmpContent.count + xmpId.count + 2)
        xmpApp1.append(contentsOf: packUInt16(xmpLen))
        xmpApp1.append(xmpId)
        xmpApp1.append(xmpContent)

        // 5. 重新拼装完整文件
        var finalData = Data()
        if pureImageData.count >= 2 {
            finalData.append(pureImageData.prefix(2)) // SOI
            finalData.append(exifApp1)
            finalData.append(xmpApp1)
            finalData.append(pureImageData.dropFirst(2)) // 图像主体
            try finalData.write(to: outputURL)
        }

        return outputURL
    }

    /// 移除旧 EXIF/XMP APP1 段，但不触碰 JPEG 压缩像素。
    /// 其他 APP 段（如 ICC profile）会原样保留。
    static func removingExistingExifAndXMP(from jpeg: Data) throws -> Data {
        guard jpeg.count >= 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else {
            throw ConversionError.invalidInput
        }
        var output = Data(jpeg.prefix(2))
        var index = 2

        while index + 1 < jpeg.count {
            guard jpeg[index] == 0xFF else {
                throw ConversionError.invalidInput
            }
            let marker = jpeg[index + 1]
            if marker == 0xDA || marker == 0xD9 {
                output.append(jpeg.suffix(from: index))
                return output
            }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                output.append(contentsOf: [0xFF, marker])
                index += 2
                continue
            }
            guard index + 3 < jpeg.count else { throw ConversionError.invalidInput }
            let length = Int(jpeg[index + 2]) << 8 | Int(jpeg[index + 3])
            let segmentEnd = index + 2 + length
            guard length >= 2, segmentEnd <= jpeg.count else { throw ConversionError.invalidInput }

            var shouldRemove = false
            if marker == 0xE1 {
                let payloadStart = index + 4
                let payload = jpeg[payloadStart..<segmentEnd]
                let exifHeader = Data("Exif\0\0".utf8)
                let xmpHeader = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
                shouldRemove = payload.starts(with: exifHeader) || payload.starts(with: xmpHeader)
            }
            if !shouldRemove {
                output.append(jpeg[index..<segmentEnd])
            }
            index = segmentEnd
        }
        throw ConversionError.invalidInput
    }

    private func packUInt16(_ value: UInt16) -> [UInt8] {
        return [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private func createOrientationNormalizedImage(
        from source: CGImageSource,
        properties: [String: Any]
    ) -> CGImage? {
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        let maximumPixelSize = max(width, height)

        guard maximumPixelSize > 0 else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func packUInt32(_ value: UInt32) -> [UInt8] {
        return [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    private func buildExifEntry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
        var entry = Data()
        entry.append(contentsOf: packUInt16(tag))
        entry.append(contentsOf: packUInt16(type))
        entry.append(contentsOf: packUInt32(count))
        entry.append(contentsOf: packUInt32(value))
        return entry
    }

    private func packRational(_ value: Double) -> Data {
        var data = Data()
        // 简化处理：保留 3 位小数
        let precision: Double = 1000
        let numerator = UInt32(round(abs(value) * precision))
        let denominator = UInt32(precision)
        data.append(contentsOf: packUInt32(numerator))
        data.append(contentsOf: packUInt32(denominator))
        return data
    }

    private func packGPSCoordinate(_ value: Double) -> Data {
        let absValue = abs(value)
        let degrees = floor(absValue)
        let minutes = floor((absValue - degrees) * 60.0)
        let seconds = (absValue - degrees - minutes / 60.0) * 3600.0
        
        var data = Data()
        // Degrees (Rational: numerator/denominator)
        data.append(contentsOf: packUInt32(UInt32(degrees)))
        data.append(contentsOf: packUInt32(1))
        
        // Minutes
        data.append(contentsOf: packUInt32(UInt32(minutes)))
        data.append(contentsOf: packUInt32(1))
        
        // Seconds (保留 3 位小数)
        let precision: Double = 1000
        data.append(contentsOf: packUInt32(UInt32(round(seconds * precision))))
        data.append(contentsOf: packUInt32(UInt32(precision)))
        
        return data
    }
}
