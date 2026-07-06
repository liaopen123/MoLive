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

        // 创建临时目录
        let tempDirectory = try createTempDirectory(prefix: "LivePhotoConvert")
        let tempJPEGURL = tempDirectory.appendingPathComponent("temp").appendingPathExtension("jpg")
        let outputURL = tempDirectory.appendingPathComponent("MVIMG_\(UUID().uuidString)").appendingPathExtension("jpg")

        do {
            // 获取 Live Photo 资源
            let (photoURL, videoURL) = try await getLivePhotoResources(from: livePhoto)
            defer {
                // 清理资源文件
                try? FileManager.default.removeItem(at: photoURL)
                try? FileManager.default.removeItem(at: videoURL)
            }

            // 读取照片数据和属性。CGImage 不会自动应用 EXIF Orientation，
            // 因此在转成 JPEG 时将方向烘焙进像素，避免 Android 相册忽略方向标记。
            guard let imageSource = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
                  var imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
                  let imageRef = createOrientationNormalizedImage(from: imageSource, properties: imageProperties) else {
                throw ConversionError.conversionFailed
            }

            // 将图像转换为高质量JPEG，保留原始属性
            guard let destination = CGImageDestinationCreateWithURL(
                tempJPEGURL as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                throw ConversionError.conversionFailed
            }

            // 合并原始属性和压缩质量设置
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
            
            // 合并数据
            var finalData = try Data(contentsOf: photoWithMetadata)
            
            // Motion Photo 是“完整 JPEG + 视频”。EOI (FF D9) 必须保留，
            // 否则严格的 JPEG 解码器会将文件判定为损坏。
            guard finalData.count >= 2,
                  finalData[finalData.count - 2] == 0xFF,
                  finalData[finalData.count - 1] == 0xD9 else {
                throw ConversionError.conversionFailed
            }

            // 附加视频数据并写入最终文件
            finalData.append(videoData)
            print("最终文件大小: \(finalData.count) 字节")
            try finalData.write(to: outputURL)
            
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
        
        // 首先验证文件头是否为JPEG
        guard data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8 else {
            throw ConversionError.invalidInput
        }
        
        // 查找第一个完整的JPEG图像
        var imageEndIndex = 0
        var i = 2
        var segments: [(start: Int, length: Int)] = []
        
        while i < data.count - 1 {
            guard data[i] == 0xFF else {
                i += 1
                continue
            }
            
            let marker = data[i + 1]
            
            // 如果是EOI标记（0xD9），说明找到了JPEG结束
            if marker == 0xD9 {
                imageEndIndex = i + 2
                break
            }
            
            // 如果是SOI标记（0xD8），说明找到了新的JPEG始
            if marker == 0xD8 {
                i += 2
                continue
            }
            
            // 如果是其他段标记
            if marker >= 0xE0 && marker <= 0xEF || // APP segments
               marker == 0xFE || // COM segment
               marker == 0xDB || // DQT segment
               marker == 0xC0 || marker == 0xC2 || // SOF segments
               marker == 0xC4 { // DHT segment
                
                if i + 3 < data.count {
                    let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
                    segments.append((start: i, length: length + 2))
                    i += length + 2
                    continue
                }
            }
            
            i += 1
        }
        
        guard imageEndIndex > 0 else {
            throw ConversionError.invalidInput
        }
        
        // 提取图片数据
        let imageData = data.prefix(imageEndIndex)
        
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
        
        // 查找视频数据的起始位置
        var videoStartIndex = imageEndIndex
        while videoStartIndex < data.count - 4 {
            // 检查常见的视频文件头
            if data[videoStartIndex..<min(videoStartIndex + 4, data.count)].elementsEqual([0x00, 0x00, 0x00, 0x18]) ||  // MOV
               data[videoStartIndex..<min(videoStartIndex + 4, data.count)].elementsEqual([0x66, 0x74, 0x79, 0x70]) {   // MP4
                break
            }
            videoStartIndex += 1
        }
        
        guard videoStartIndex < data.count - 4 else {
            throw ConversionError.invalidInput
        }
        
        let videoData = data.suffix(from: videoStartIndex)
        
        // 保存分离的数据
        try imageData.write(to: photoURL, options: [.atomic])
        try videoData.write(to: videoURL, options: [.atomic])
        return Self.motionPhotoPresentationTime(fromJPEGData: Data(imageData)) ?? .invalid
    }

    static func motionPhotoPresentationTime(fromJPEGData data: Data) -> CMTime? {
        let text = String(decoding: data, as: UTF8.self)
        let patterns = [
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
              let imageRef = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
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

        // 2. 生成不带任何元数据的纯净 JPEG 图像主体
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent("MVIMG_\(UUID().uuidString)")
            .appendingPathExtension("jpg")

        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError.conversionFailed
        }
        // 使用空的元数据字典写入，并确保移除 alpha 通道以解决内存警告
        let options: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: 1.0,
            kCGImagePropertyHasAlpha as String: false
        ]
        CGImageDestinationAddImage(destination, imageRef, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.conversionFailed
        }
        let pureImageData = try Data(contentsOf: outputURL)

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
                    xmlns:GCamera="http://ns.google.com/photos/1.0/camera/">
                 <GCamera:MicroVideo>1</GCamera:MicroVideo>
                 <GCamera:MicroVideoVersion>1</GCamera:MicroVideoVersion>
                 <GCamera:MicroVideoOffset>\(offset)</GCamera:MicroVideoOffset>
                 <GCamera:MicroVideoPresentationTimestampUs>\(presentationTimestampUs)</GCamera:MicroVideoPresentationTimestampUs>
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
