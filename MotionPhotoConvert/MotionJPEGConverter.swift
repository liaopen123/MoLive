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
        try await separateImageAndVideo(from: data, photoURL: tempPhotoURL, videoURL: tempVideoURL)
        
        // 处理视频数据
        let videoData = try Data(contentsOf: tempVideoURL)
        _ = try await processVideo(from: videoData, to: processedVideoURL)
        
        // 创建 Live Photo
        let livePhoto = try await createLivePhoto(photoURL: tempPhotoURL, videoURL: processedVideoURL)
        
        // 保存到相册
        try await saveLivePhotoToLibrary(photoURL: tempPhotoURL, videoURL: processedVideoURL)
        
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

            // 读取照片数据和属性
            guard let imageSource = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
                  let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
                  let imageRef = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
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
            var finalProperties = imageProperties
            finalProperties[kCGImageDestinationLossyCompressionQuality as String] = 1.0

            CGImageDestinationAddImage(destination, imageRef, finalProperties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ConversionError.conversionFailed
            }

            // 处理视频数据
            let videoData = try await processVideoForMotionJPEG(from: videoURL)
            print("视频数据大小: \(videoData.count) 字节")
            
            // 添加元数据
            let photoWithMetadata = try await addXiaomiMetadata(to: tempJPEGURL, offset: videoData.count)
            let photoData = try Data(contentsOf: photoWithMetadata)
            print("添加元数据后的照片大小: \(photoData.count) 字节")
            
            // 合并数据
            var finalData = try Data(contentsOf: photoWithMetadata)
            
            // 确保JPEG文件结构完整
            if finalData.count >= 2 && finalData[finalData.count - 2] == 0xFF && finalData[finalData.count - 1] == 0xD9 {
                finalData.removeLast(2)
            }
            
            // 附加视频数据并写入最终文件
            finalData.append(videoData)
            print("最终文件大小: \(finalData.count) 字节")
            try finalData.write(to: outputURL)
            
            return outputURL
        } catch {
            // 如果处理过程中出错，清理所有临时文件
            try? FileManager.default.removeItem(at: tempDirectory)
            throw error
        }
    }
    
    private func separateImageAndVideo(from data: Data, photoURL: URL, videoURL: URL) async throws {
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
    }
    
    private func addXiaomiMetadata(to url: URL, offset: Int) async throws -> URL {
        // 读��原始图片数据
        let imageData = try Data(contentsOf: url)

        // 创建输出 URL
        let outputURL = url.deletingLastPathComponent()
            .appendingPathComponent("MVIMG_\(UUID().uuidString)")
            .appendingPathExtension("jpg")

        // 创建 CGImageSource 来处理图像和元数据
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let imageRef = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            throw ConversionError.conversionFailed
        }
        
        // 提取基本 EXIF 信息
        var orientation: Int = 1 // 默认正常方向
        if let tiffDict = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let orientationValue = tiffDict[kCGImagePropertyTIFFOrientation as String] as? Int {
            orientation = orientationValue
        } else if let orientationValue = metadata[kCGImagePropertyOrientation as String] as? Int {
            orientation = orientationValue
        }
        
        // 提取拍摄时间
        var dateTime: String? = nil
        var dateTimeOriginal: String? = nil
        if let tiffDict = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            dateTime = tiffDict[kCGImagePropertyTIFFDateTime as String] as? String
        }
        if let exifDict = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            dateTimeOriginal = exifDict[kCGImagePropertyExifDateTimeOriginal as String] as? String
            if dateTime == nil {
                dateTime = exifDict[kCGImagePropertyExifDateTimeDigitized as String] as? String
            }
        }
        
        // 提取拍摄参数
        var make: String? = nil
        var model: String? = nil
        var iso: Int? = nil
        var fNumber: Double? = nil
        var exposureTime: Double? = nil
        var focalLength: Double? = nil
        
        if let tiffDict = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            make = tiffDict[kCGImagePropertyTIFFMake as String] as? String
            model = tiffDict[kCGImagePropertyTIFFModel as String] as? String
        }
        
        if let exifDict = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let isoValue = exifDict[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], !isoValue.isEmpty {
                iso = isoValue[0]
            } else if let isoValue = exifDict[kCGImagePropertyExifISOSpeedRatings as String] as? Int {
                iso = isoValue
            }
            fNumber = exifDict[kCGImagePropertyExifFNumber as String] as? Double
            exposureTime = exifDict[kCGImagePropertyExifExposureTime as String] as? Double
            focalLength = exifDict[kCGImagePropertyExifFocalLength as String] as? Double
        }
        
        // 提取 GPS 信息
        var gpsLatitude: Double? = nil
        var gpsLongitude: Double? = nil
        var gpsAltitude: Double? = nil
        var gpsLatitudeRef: String? = nil
        var gpsLongitudeRef: String? = nil
        var gpsAltitudeRef: UInt8? = nil
        
        if let gpsDict = metadata[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            gpsLatitude = gpsDict[kCGImagePropertyGPSLatitude as String] as? Double
            gpsLongitude = gpsDict[kCGImagePropertyGPSLongitude as String] as? Double
            gpsAltitude = gpsDict[kCGImagePropertyGPSAltitude as String] as? Double
            gpsLatitudeRef = gpsDict[kCGImagePropertyGPSLatitudeRef as String] as? String
            gpsLongitudeRef = gpsDict[kCGImagePropertyGPSLongitudeRef as String] as? String
            if let altRef = gpsDict[kCGImagePropertyGPSAltitudeRef as String] as? Int {
                gpsAltitudeRef = UInt8(altRef)
            }
        }

        // 创建目标图像
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL,
                                                              UTType.jpeg.identifier as CFString,
                                                              1, nil) else {
            throw ConversionError.conversionFailed
        }

        // 创建 XMP 元数据
        let xmpString = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.0">
           <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
              <rdf:Description rdf:about=""
                    xmlns:GCamera="http://ns.google.com/photos/1.0/camera/">
                 <GCamera:MicroVideo>1</GCamera:MicroVideo>
                 <GCamera:MicroVideoVersion>1</GCamera:MicroVideoVersion>
                 <GCamera:MicroVideoOffset>\(offset)</GCamera:MicroVideoOffset>
              </rdf:Description>
           </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let xmpIdentifier = "http://ns.adobe.com/xap/1.0/\0"
        guard let xmpIdentifierData = xmpIdentifier.data(using: .utf8) else {
            throw ConversionError.conversionFailed
        }

        let xmpData = xmpString.data(using: .utf8) ?? Data()
        let xmpSegmentLength = xmpIdentifierData.count + xmpData.count + 2

        var xmpSegment = Data([0xFF, 0xE1])
        xmpSegment.append(UInt8(xmpSegmentLength >> 8))
        xmpSegment.append(UInt8(xmpSegmentLength & 0xFF))
        xmpSegment.append(xmpIdentifierData)
        xmpSegment.append(xmpData)

        // 构建 EXIF 段（包含方向、拍摄参数、时间、GPS 和 0x8897 标签）
        let exifData = try buildExifDataWithMetadata(
            orientation: orientation,
            dateTime: dateTime,
            dateTimeOriginal: dateTimeOriginal,
            make: make,
            model: model,
            iso: iso,
            fNumber: fNumber,
            exposureTime: exposureTime,
            focalLength: focalLength,
            gpsLatitude: gpsLatitude,
            gpsLongitude: gpsLongitude,
            gpsAltitude: gpsAltitude,
            gpsLatitudeRef: gpsLatitudeRef,
            gpsLongitudeRef: gpsLongitudeRef,
            gpsAltitudeRef: gpsAltitudeRef
        )
        
        // 创建完整的 EXIF APP1 段
        var exifSegment = Data()
        exifSegment.append(contentsOf: [0xFF, 0xE1])
        let exifLength = 2 + 6 + exifData.count // 2(长度字段) + 6(Exif\0\0) + TIFF数据长度
        exifSegment.append(contentsOf: [UInt8(exifLength >> 8), UInt8(exifLength & 0xFF)])
        exifSegment.append(contentsOf: "Exif\0\0".data(using: .ascii)!)
        exifSegment.append(exifData)

        // 设置图像和元数据（保留所有原始 EXIF 信息，包括拍摄参数、时间、GPS）
        CGImageDestinationAddImage(destination, imageRef, metadata as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.conversionFailed
        }

        // 读取生成的图像数据
        var finalData = try Data(contentsOf: outputURL)
        
        // 在 JPEG 文件中插入 XMP 段
        // 保留 CGImageDestination 生成的 EXIF 段（包含所有拍摄参数、时间、GPS）
        // 只添加 XMP 段，0x8897 标签通过替换 EXIF 段来添加
        if finalData.count >= 2 {
            var insertPosition = 2 // 跳过 SOI (0xFF 0xD8)
            var foundExif = false
            var exifStartPos = -1
            var exifLength = 0
            
            // 查找现有的 EXIF 段
            while insertPosition < finalData.count - 1 {
                if finalData[insertPosition] == 0xFF {
                    let marker = finalData[insertPosition + 1]
                    
                    // 如果是 APP1 段 (0xE1)，可能是 EXIF
                    if marker == 0xE1 && insertPosition + 3 < finalData.count {
                        let length = (Int(finalData[insertPosition + 2]) << 8) | Int(finalData[insertPosition + 3])
                        // 检查是否是 EXIF 段
                        if insertPosition + 10 < finalData.count {
                            let exifHeader = finalData[(insertPosition + 4)..<(insertPosition + 10)]
                            if String(data: exifHeader, encoding: .ascii) == "Exif\0\0" {
                                foundExif = true
                                exifStartPos = insertPosition
                                exifLength = length + 2
                                break
                            }
                        }
                        insertPosition += 2 + length
                        continue
                    } else if marker >= 0xE0 && marker <= 0xEF {
                        // 其他 APP 段
                        if insertPosition + 3 < finalData.count {
                            let length = (Int(finalData[insertPosition + 2]) << 8) | Int(finalData[insertPosition + 3])
                            insertPosition += 2 + length
                            continue
                        }
                    } else if marker == 0xD8 || marker == 0xD9 {
                        insertPosition += 2
                        continue
                    } else {
                        // 找到插入位置
                        break
                    }
                }
                insertPosition += 1
            }
            
            if foundExif {
                // 找到了原有的 EXIF 段，替换它
                // 新的 EXIF 段包含方向、0x8897 标签，但会丢失其他信息
                // 为了保留拍摄参数、时间、GPS，我们需要在原有 EXIF 中添加 0x8897
                // 但这太复杂，暂时替换为简化版本（只包含方向和 0x8897）
                // TODO: 未来可以解析原有 EXIF 并添加 0x8897 标签
                var newData = Data()
                newData.append(finalData.prefix(exifStartPos))
                newData.append(exifSegment)   // 新的 EXIF 段（包含方向和 0x8897）
                newData.append(xmpSegment)     // XMP 段
                newData.append(finalData.suffix(from: exifStartPos + exifLength))
                try newData.write(to: outputURL)
            } else {
                // 没有找到 EXIF 段，插入新的 EXIF 和 XMP 段
                var newData = Data()
                newData.append(finalData.prefix(insertPosition))
                newData.append(exifSegment)   // EXIF 段（包含方向和 0x8897）
                newData.append(xmpSegment)    // XMP 段
                newData.append(finalData.suffix(from: insertPosition))
                try newData.write(to: outputURL)
            }
        }

        return outputURL
    }
    
    // 构建 EXIF 数据（包含方向、拍摄参数、时间、GPS 和 0x8897 标签）
    private func buildExifDataWithMetadata(
        orientation: Int,
        dateTime: String?,
        dateTimeOriginal: String?,
        make: String?,
        model: String?,
        iso: Int?,
        fNumber: Double?,
        exposureTime: Double?,
        focalLength: Double?,
        gpsLatitude: Double?,
        gpsLongitude: Double?,
        gpsAltitude: Double?,
        gpsLatitudeRef: String?,
        gpsLongitudeRef: String?,
        gpsAltitudeRef: UInt8?
    ) throws -> Data {
        var exifData = Data()
        
        // TIFF 头部
        exifData.append(contentsOf: [0x4D, 0x4D]) // 大端字节序 (MM)
        exifData.append(contentsOf: [0x00, 0x2A]) // TIFF 标识符
        
        // IFD0 偏移量
        let ifd0Offset: UInt32 = 8
        exifData.append(contentsOf: [
            UInt8((ifd0Offset >> 24) & 0xFF),
            UInt8((ifd0Offset >> 16) & 0xFF),
            UInt8((ifd0Offset >> 8) & 0xFF),
            UInt8(ifd0Offset & 0xFF)
        ])
        
        // 计算各个 IFD 的偏移量
        var currentOffset: UInt32 = 8 + 2 // TIFF头部(8) + IFD0条目数量(2)
        
        // 计算需要的条目数量
        var ifd0EntryCount: UInt16 = 1 // Orientation（总是包含）
        if dateTime != nil { ifd0EntryCount += 1 } // DateTime
        if make != nil { ifd0EntryCount += 1 } // Make
        if model != nil { ifd0EntryCount += 1 } // Model
        ifd0EntryCount += 1 // ExifIFD 指针（必需）
        if gpsLatitude != nil && gpsLongitude != nil { ifd0EntryCount += 1 } // GPSIFD 指针
        
        currentOffset += UInt32(ifd0EntryCount * 12) // 每个条目12字节
        currentOffset += 4 // 下一个IFD指针
        
        let exifIFDOffset = currentOffset
        var exifIFDEntryCount: UInt16 = 0
        if dateTimeOriginal != nil { exifIFDEntryCount += 1 }
        if iso != nil { exifIFDEntryCount += 1 }
        if fNumber != nil { exifIFDEntryCount += 1 }
        if exposureTime != nil { exifIFDEntryCount += 1 }
        if focalLength != nil { exifIFDEntryCount += 1 }
        exifIFDEntryCount += 1 // 0x8897 标签（必需）
        
        currentOffset += 2 // ExifIFD 条目数量
        currentOffset += UInt32(exifIFDEntryCount * 12) // ExifIFD 条目
        currentOffset += 4 // 下一个IFD指针
        
        let gpsIFDOffset: UInt32? = (gpsLatitude != nil && gpsLongitude != nil) ? currentOffset : nil
        var gpsIFDEntryCount: UInt16 = 0
        if gpsIFDOffset != nil {
            if gpsLatitude != nil { gpsIFDEntryCount += 1 } // GPSLatitudeRef
            if gpsLatitude != nil { gpsIFDEntryCount += 1 } // GPSLatitude
            if gpsLongitude != nil { gpsIFDEntryCount += 1 } // GPSLongitudeRef
            if gpsLongitude != nil { gpsIFDEntryCount += 1 } // GPSLongitude
            if gpsAltitude != nil { gpsIFDEntryCount += 1 } // GPSAltitudeRef
            if gpsAltitude != nil { gpsIFDEntryCount += 1 } // GPSAltitude
        }
        
        // IFD0 条目数量
        exifData.append(contentsOf: [
            UInt8(ifd0EntryCount >> 8),
            UInt8(ifd0EntryCount & 0xFF)
        ])
        
        var stringDataOffset = currentOffset
        if gpsIFDOffset != nil {
            stringDataOffset += 2 + UInt32(gpsIFDEntryCount * 12) + 4
        }
        
        // IFD0 条目
        var entryOffset: UInt32 = 8 + 2 + 2 // TIFF头部 + IFD0条目数量 + 当前条目开始
        
        // Orientation 条目 (Tag 0x0112) - 总是包含
        exifData.append(contentsOf: [0x01, 0x12]) // Tag: Orientation
        exifData.append(contentsOf: [0x00, 0x03]) // Type: SHORT
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
        let orientationValue = UInt16(orientation)
        exifData.append(contentsOf: [
            UInt8((orientationValue >> 8) & 0xFF),
            UInt8(orientationValue & 0xFF),
            0x00, 0x00
        ])
        entryOffset += 12
        
        // DateTime 条目 (Tag 0x0132)
        if let dateTime = dateTime {
            exifData.append(contentsOf: [0x01, 0x32]) // Tag: DateTime
            exifData.append(contentsOf: [0x00, 0x02]) // Type: ASCII
            let dateTimeData = dateTime.data(using: .ascii) ?? Data()
            let dateTimeLength = UInt32(dateTimeData.count + 1) // +1 for null terminator
            exifData.append(contentsOf: [
                UInt8((dateTimeLength >> 24) & 0xFF),
                UInt8((dateTimeLength >> 16) & 0xFF),
                UInt8((dateTimeLength >> 8) & 0xFF),
                UInt8(dateTimeLength & 0xFF)
            ])
            if dateTimeLength <= 4 {
                // 值直接存储在偏移量字段
                var valueData = dateTimeData
                while valueData.count < 4 {
                    valueData.append(0)
                }
                exifData.append(valueData.prefix(4))
            } else {
                // 值存储在偏移量指向的位置
                exifData.append(contentsOf: [
                    UInt8((stringDataOffset >> 24) & 0xFF),
                    UInt8((stringDataOffset >> 16) & 0xFF),
                    UInt8((stringDataOffset >> 8) & 0xFF),
                    UInt8(stringDataOffset & 0xFF)
                ])
                // 字符串数据会在后面追加
            }
            entryOffset += 12
            if dateTimeLength > 4 {
                stringDataOffset += dateTimeLength
            }
        }
        
        // Make 条目 (Tag 0x010F)
        if let make = make {
            exifData.append(contentsOf: [0x01, 0x0F]) // Tag: Make
            exifData.append(contentsOf: [0x00, 0x02]) // Type: ASCII
            let makeData = make.data(using: .ascii) ?? Data()
            let makeLength = UInt32(makeData.count + 1)
            exifData.append(contentsOf: [
                UInt8((makeLength >> 24) & 0xFF),
                UInt8((makeLength >> 16) & 0xFF),
                UInt8((makeLength >> 8) & 0xFF),
                UInt8(makeLength & 0xFF)
            ])
            if makeLength <= 4 {
                var valueData = makeData
                while valueData.count < 4 {
                    valueData.append(0)
                }
                exifData.append(valueData.prefix(4))
            } else {
                exifData.append(contentsOf: [
                    UInt8((stringDataOffset >> 24) & 0xFF),
                    UInt8((stringDataOffset >> 16) & 0xFF),
                    UInt8((stringDataOffset >> 8) & 0xFF),
                    UInt8(stringDataOffset & 0xFF)
                ])
            }
            entryOffset += 12
            if makeLength > 4 {
                stringDataOffset += makeLength
            }
        }
        
        // Model 条目 (Tag 0x0110)
        if let model = model {
            exifData.append(contentsOf: [0x01, 0x10]) // Tag: Model
            exifData.append(contentsOf: [0x00, 0x02]) // Type: ASCII
            let modelData = model.data(using: .ascii) ?? Data()
            let modelLength = UInt32(modelData.count + 1)
            exifData.append(contentsOf: [
                UInt8((modelLength >> 24) & 0xFF),
                UInt8((modelLength >> 16) & 0xFF),
                UInt8((modelLength >> 8) & 0xFF),
                UInt8(modelLength & 0xFF)
            ])
            if modelLength <= 4 {
                var valueData = modelData
                while valueData.count < 4 {
                    valueData.append(0)
                }
                exifData.append(valueData.prefix(4))
            } else {
                exifData.append(contentsOf: [
                    UInt8((stringDataOffset >> 24) & 0xFF),
                    UInt8((stringDataOffset >> 16) & 0xFF),
                    UInt8((stringDataOffset >> 8) & 0xFF),
                    UInt8(stringDataOffset & 0xFF)
                ])
            }
            entryOffset += 12
            if modelLength > 4 {
                stringDataOffset += modelLength
            }
        }
        
        // ExifIFD 指针条目 (Tag 0x8769)
        exifData.append(contentsOf: [0x87, 0x69]) // Tag 34665
        exifData.append(contentsOf: [0x00, 0x04]) // Type: LONG
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
        exifData.append(contentsOf: [
            UInt8((exifIFDOffset >> 24) & 0xFF),
            UInt8((exifIFDOffset >> 16) & 0xFF),
            UInt8((exifIFDOffset >> 8) & 0xFF),
            UInt8(exifIFDOffset & 0xFF)
        ])
        
        // GPSIFD 指针条目 (Tag 0x8825)
        if let gpsIFDOffset = gpsIFDOffset {
            exifData.append(contentsOf: [0x88, 0x25]) // Tag 34853
            exifData.append(contentsOf: [0x00, 0x04]) // Type: LONG
            exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
            exifData.append(contentsOf: [
                UInt8((gpsIFDOffset >> 24) & 0xFF),
                UInt8((gpsIFDOffset >> 16) & 0xFF),
                UInt8((gpsIFDOffset >> 8) & 0xFF),
                UInt8(gpsIFDOffset & 0xFF)
            ])
        }
        
        // IFD0 的下一个 IFD 偏移量 (0 表示没有下一个)
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        
        // ExifIFD
        exifData.append(contentsOf: [
            UInt8(exifIFDEntryCount >> 8),
            UInt8(exifIFDEntryCount & 0xFF)
        ])
        
        var exifStringDataOffset = stringDataOffset
        if gpsIFDOffset != nil {
            exifStringDataOffset += 2 + UInt32(gpsIFDEntryCount * 12) + 4
        }
        
        // DateTimeOriginal 条目 (Tag 0x9003)
        if let dateTimeOriginal = dateTimeOriginal {
            exifData.append(contentsOf: [0x90, 0x03]) // Tag: DateTimeOriginal
            exifData.append(contentsOf: [0x00, 0x02]) // Type: ASCII
            let dtData = dateTimeOriginal.data(using: .ascii) ?? Data()
            let dtLength = UInt32(dtData.count + 1)
            exifData.append(contentsOf: [
                UInt8((dtLength >> 24) & 0xFF),
                UInt8((dtLength >> 16) & 0xFF),
                UInt8((dtLength >> 8) & 0xFF),
                UInt8(dtLength & 0xFF)
            ])
            if dtLength <= 4 {
                var valueData = dtData
                while valueData.count < 4 {
                    valueData.append(0)
                }
                exifData.append(valueData.prefix(4))
            } else {
                exifData.append(contentsOf: [
                    UInt8((exifStringDataOffset >> 24) & 0xFF),
                    UInt8((exifStringDataOffset >> 16) & 0xFF),
                    UInt8((exifStringDataOffset >> 8) & 0xFF),
                    UInt8(exifStringDataOffset & 0xFF)
                ])
                exifStringDataOffset += dtLength
            }
        }
        
        // ISO 条目 (Tag 0x8827)
        if let iso = iso {
            exifData.append(contentsOf: [0x88, 0x27]) // Tag: ISOSpeedRatings
            exifData.append(contentsOf: [0x00, 0x03]) // Type: SHORT
            exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
            let isoValue = UInt16(iso)
            exifData.append(contentsOf: [
                UInt8((isoValue >> 8) & 0xFF),
                UInt8(isoValue & 0xFF),
                0x00, 0x00
            ])
        }
        
        // FNumber 条目 (Tag 0x829D)
        if let fNumber = fNumber {
            exifData.append(contentsOf: [0x82, 0x9D]) // Tag: FNumber
            exifData.append(contentsOf: [0x00, 0x05]) // Type: RATIONAL
            exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
            // RATIONAL 值存储在偏移量指向的位置
            exifData.append(contentsOf: [
                UInt8((exifStringDataOffset >> 24) & 0xFF),
                UInt8((exifStringDataOffset >> 16) & 0xFF),
                UInt8((exifStringDataOffset >> 8) & 0xFF),
                UInt8(exifStringDataOffset & 0xFF)
            ])
            // 后面会追加 RATIONAL 值
            exifStringDataOffset += 8
        }
        
        // ExposureTime 条目 (Tag 0x829A)
        if let exposureTime = exposureTime {
            exifData.append(contentsOf: [0x82, 0x9A]) // Tag: ExposureTime
            exifData.append(contentsOf: [0x00, 0x05]) // Type: RATIONAL
            exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
            exifData.append(contentsOf: [
                UInt8((exifStringDataOffset >> 24) & 0xFF),
                UInt8((exifStringDataOffset >> 16) & 0xFF),
                UInt8((exifStringDataOffset >> 8) & 0xFF),
                UInt8(exifStringDataOffset & 0xFF)
            ])
            exifStringDataOffset += 8
        }
        
        // FocalLength 条目 (Tag 0x920A)
        if let focalLength = focalLength {
            exifData.append(contentsOf: [0x92, 0x0A]) // Tag: FocalLength
            exifData.append(contentsOf: [0x00, 0x05]) // Type: RATIONAL
            exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
            exifData.append(contentsOf: [
                UInt8((exifStringDataOffset >> 24) & 0xFF),
                UInt8((exifStringDataOffset >> 16) & 0xFF),
                UInt8((exifStringDataOffset >> 8) & 0xFF),
                UInt8(exifStringDataOffset & 0xFF)
            ])
            exifStringDataOffset += 8
        }
        
        // 0x8897 标签条目（Motion Photo 标识）
        exifData.append(contentsOf: [0x88, 0x97]) // Tag
        exifData.append(contentsOf: [0x00, 0x01]) // Type: BYTE
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
        exifData.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // Value: 1
        
        // ExifIFD 的下一个 IFD 偏移量
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        
        // GPSIFD（如果有 GPS 信息）
        if let gpsIFDOffset = gpsIFDOffset {
            exifData.append(contentsOf: [
                UInt8(gpsIFDEntryCount >> 8),
                UInt8(gpsIFDEntryCount & 0xFF)
            ])
            
            var gpsStringDataOffset = exifStringDataOffset
            
            // GPSLatitudeRef (Tag 0x0001) - 如果有纬度就添加
            if let gpsLatitude = gpsLatitude {
                exifData.append(contentsOf: [0x00, 0x01]) // Tag: GPSLatitudeRef
                exifData.append(contentsOf: [0x00, 0x02]) // Type: ASCII
                exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x02]) // Count: 2
                if let gpsLatitudeRef = gpsLatitudeRef {
                    let refData = gpsLatitudeRef.data(using: .ascii) ?? Data()
                    if refData.count >= 1 {
                        exifData.append(contentsOf: [
                            UInt8(refData[0]),
                            0x00,
                            0x00,
                            0x00
                        ])
                    } else {
                        exifData.append(contentsOf: [0x4E, 0x00, 0x00, 0x00]) // 默认 'N'
                    }
                } else {
                    exifData.append(contentsOf: [0x4E, 0x00, 0x00, 0x00]) // 默认 'N'
                }
            }
            
            // GPSLatitude (Tag 0x0002)
            if let gpsLatitude = gpsLatitude {
                exifData.append(contentsOf: [0x00, 0x02]) // Tag: GPSLatitude
                exifData.append(contentsOf: [0x00, 0x05]) // Type: RATIONAL
                exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x03]) // Count: 3 (度/分/秒)
                exifData.append(contentsOf: [
                    UInt8((gpsStringDataOffset >> 24) & 0xFF),
                    UInt8((gpsStringDataOffset >> 16) & 0xFF),
                    UInt8((gpsStringDataOffset >> 8) & 0xFF),
                    UInt8(gpsStringDataOffset & 0xFF)
                ])
                gpsStringDataOffset += 24 // 3个 RATIONAL，每个8字节
            }
            
            // GPSLongitudeRef (Tag 0x0003) - 如果有经度就添加
            if let gpsLongitude = gpsLongitude {
                exifData.append(contentsOf: [0x00, 0x03]) // Tag: GPSLongitudeRef
                exifData.append(contentsOf: [0x00, 0x02]) // Type: ASCII
                exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x02]) // Count: 2
                if let gpsLongitudeRef = gpsLongitudeRef {
                    let refData = gpsLongitudeRef.data(using: .ascii) ?? Data()
                    if refData.count >= 1 {
                        exifData.append(contentsOf: [
                            UInt8(refData[0]),
                            0x00,
                            0x00,
                            0x00
                        ])
                    } else {
                        exifData.append(contentsOf: [0x45, 0x00, 0x00, 0x00]) // 默认 'E'
                    }
                } else {
                    exifData.append(contentsOf: [0x45, 0x00, 0x00, 0x00]) // 默认 'E'
                }
            }
            
            // GPSLongitude (Tag 0x0004)
            if let gpsLongitude = gpsLongitude {
                exifData.append(contentsOf: [0x00, 0x04]) // Tag: GPSLongitude
                exifData.append(contentsOf: [0x00, 0x05]) // Type: RATIONAL
                exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x03]) // Count: 3
                exifData.append(contentsOf: [
                    UInt8((gpsStringDataOffset >> 24) & 0xFF),
                    UInt8((gpsStringDataOffset >> 16) & 0xFF),
                    UInt8((gpsStringDataOffset >> 8) & 0xFF),
                    UInt8(gpsStringDataOffset & 0xFF)
                ])
                gpsStringDataOffset += 24
            }
            
            // GPSAltitudeRef (Tag 0x0005) - 如果有海拔就添加
            if let gpsAltitude = gpsAltitude {
                exifData.append(contentsOf: [0x00, 0x05]) // Tag: GPSAltitudeRef
                exifData.append(contentsOf: [0x00, 0x01]) // Type: BYTE
                exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
                let altRef = gpsAltitudeRef ?? 0 // 默认 0 (海平面以上)
                exifData.append(contentsOf: [altRef, 0x00, 0x00, 0x00])
            }
            
            // GPSAltitude (Tag 0x0006)
            if let gpsAltitude = gpsAltitude {
                exifData.append(contentsOf: [0x00, 0x06]) // Tag: GPSAltitude
                exifData.append(contentsOf: [0x00, 0x05]) // Type: RATIONAL
                exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
                exifData.append(contentsOf: [
                    UInt8((gpsStringDataOffset >> 24) & 0xFF),
                    UInt8((gpsStringDataOffset >> 16) & 0xFF),
                    UInt8((gpsStringDataOffset >> 8) & 0xFF),
                    UInt8(gpsStringDataOffset & 0xFF)
                ])
                gpsStringDataOffset += 8
            }
            
            // GPSIFD 的下一个 IFD 偏移量
            exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
            
            // 追加 GPS RATIONAL 值
            if let gpsLatitude = gpsLatitude {
                // 将度数转换为度/分/秒
                let degrees = abs(gpsLatitude)
                let deg = UInt32(degrees)
                let minutes = (degrees - Double(deg)) * 60.0
                let min = UInt32(minutes)
                let seconds = (minutes - Double(min)) * 60.0
                let sec = UInt32(seconds * 1000000) // 微秒精度
                
                // 度
                exifData.append(contentsOf: [
                    UInt8((deg >> 24) & 0xFF), UInt8((deg >> 16) & 0xFF), UInt8((deg >> 8) & 0xFF), UInt8(deg & 0xFF),
                    0x00, 0x00, 0x00, 0x01
                ])
                // 分
                exifData.append(contentsOf: [
                    UInt8((min >> 24) & 0xFF), UInt8((min >> 16) & 0xFF), UInt8((min >> 8) & 0xFF), UInt8(min & 0xFF),
                    0x00, 0x00, 0x00, 0x01
                ])
                // 秒
                exifData.append(contentsOf: [
                    UInt8((sec >> 24) & 0xFF), UInt8((sec >> 16) & 0xFF), UInt8((sec >> 8) & 0xFF), UInt8(sec & 0xFF),
                    0x00, 0x0F, 0x42, 0x40 // 1000000
                ])
            }
            
            if let gpsLongitude = gpsLongitude {
                let degrees = abs(gpsLongitude)
                let deg = UInt32(degrees)
                let minutes = (degrees - Double(deg)) * 60.0
                let min = UInt32(minutes)
                let seconds = (minutes - Double(min)) * 60.0
                let sec = UInt32(seconds * 1000000)
                
                exifData.append(contentsOf: [
                    UInt8((deg >> 24) & 0xFF), UInt8((deg >> 16) & 0xFF), UInt8((deg >> 8) & 0xFF), UInt8(deg & 0xFF),
                    0x00, 0x00, 0x00, 0x01
                ])
                exifData.append(contentsOf: [
                    UInt8((min >> 24) & 0xFF), UInt8((min >> 16) & 0xFF), UInt8((min >> 8) & 0xFF), UInt8(min & 0xFF),
                    0x00, 0x00, 0x00, 0x01
                ])
                exifData.append(contentsOf: [
                    UInt8((sec >> 24) & 0xFF), UInt8((sec >> 16) & 0xFF), UInt8((sec >> 8) & 0xFF), UInt8(sec & 0xFF),
                    0x00, 0x0F, 0x42, 0x40
                ])
            }
            
            if let gpsAltitude = gpsAltitude {
                let altitude = abs(gpsAltitude)
                let alt = UInt32(altitude * 100) // 转换为厘米
                exifData.append(contentsOf: [
                    UInt8((alt >> 24) & 0xFF), UInt8((alt >> 16) & 0xFF), UInt8((alt >> 8) & 0xFF), UInt8(alt & 0xFF),
                    0x00, 0x00, 0x00, 0x64 // 100
                ])
            }
        }
        
        // 追加字符串数据
        var stringData = Data()
        
        if let dateTime = dateTime {
            let dateTimeData = dateTime.data(using: .ascii) ?? Data()
            if dateTimeData.count + 1 > 4 {
                stringData.append(dateTimeData)
                stringData.append(0) // null terminator
            }
        }
        
        if let make = make {
            let makeData = make.data(using: .ascii) ?? Data()
            if makeData.count + 1 > 4 {
                stringData.append(makeData)
                stringData.append(0)
            }
        }
        
        if let model = model {
            let modelData = model.data(using: .ascii) ?? Data()
            if modelData.count + 1 > 4 {
                stringData.append(modelData)
                stringData.append(0)
            }
        }
        
        if let dateTimeOriginal = dateTimeOriginal {
            let dtData = dateTimeOriginal.data(using: .ascii) ?? Data()
            if dtData.count + 1 > 4 {
                stringData.append(dtData)
                stringData.append(0)
            }
        }
        
        // 追加 RATIONAL 值
        if let fNumber = fNumber {
            let numerator = UInt32(fNumber * 100)
            stringData.append(contentsOf: [
                UInt8((numerator >> 24) & 0xFF), UInt8((numerator >> 16) & 0xFF), UInt8((numerator >> 8) & 0xFF), UInt8(numerator & 0xFF),
                0x00, 0x00, 0x00, 0x64 // 100
            ])
        }
        
        if let exposureTime = exposureTime {
            let numerator = UInt32(exposureTime * 1000000)
            stringData.append(contentsOf: [
                UInt8((numerator >> 24) & 0xFF), UInt8((numerator >> 16) & 0xFF), UInt8((numerator >> 8) & 0xFF), UInt8(numerator & 0xFF),
                0x00, 0x0F, 0x42, 0x40 // 1000000
            ])
        }
        
        if let focalLength = focalLength {
            let numerator = UInt32(focalLength * 100)
            stringData.append(contentsOf: [
                UInt8((numerator >> 24) & 0xFF), UInt8((numerator >> 16) & 0xFF), UInt8((numerator >> 8) & 0xFF), UInt8(numerator & 0xFF),
                0x00, 0x00, 0x00, 0x64 // 100
            ])
        }
        
        exifData.append(stringData)
        
        return exifData
    }
    
    // 构建 EXIF 数据（简化版本，只包含方向和 0x8897）
    // 注意：这个函数已不再使用，保留用于参考
    private func buildSimpleExifData(orientation: Int) throws -> Data {
        // 简化版本只包含方向和 0x8897 标签
        var exifData = Data()
        
        // TIFF 头部
        exifData.append(contentsOf: [0x4D, 0x4D]) // 大端字节序 (MM)
        exifData.append(contentsOf: [0x00, 0x2A]) // TIFF 标识符
        
        // IFD0 偏移量
        let ifd0Offset: UInt32 = 8
        exifData.append(contentsOf: [
            UInt8((ifd0Offset >> 24) & 0xFF),
            UInt8((ifd0Offset >> 16) & 0xFF),
            UInt8((ifd0Offset >> 8) & 0xFF),
            UInt8(ifd0Offset & 0xFF)
        ])
        
        // IFD0
        let orientationOffset: UInt32 = 8 + 2 + 12
        let exifIFDOffset: UInt32 = orientationOffset + 12 + 4
        
        // IFD0 条目数量（Orientation + ExifIFD指针）
        exifData.append(contentsOf: [0x00, 0x02])
        
        // Orientation 条目 (Tag 0x0112)
        exifData.append(contentsOf: [0x01, 0x12]) // Tag: Orientation
        exifData.append(contentsOf: [0x00, 0x03]) // Type: SHORT
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
        let orientationValue = UInt16(orientation)
        exifData.append(contentsOf: [
            UInt8((orientationValue >> 8) & 0xFF),
            UInt8(orientationValue & 0xFF),
            0x00, 0x00
        ])
        
        // ExifIFD 指针条目
        exifData.append(contentsOf: [0x87, 0x69]) // Tag 34665
        exifData.append(contentsOf: [0x00, 0x04]) // Type: LONG
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
        exifData.append(contentsOf: [
            UInt8((exifIFDOffset >> 24) & 0xFF),
            UInt8((exifIFDOffset >> 16) & 0xFF),
            UInt8((exifIFDOffset >> 8) & 0xFF),
            UInt8(exifIFDOffset & 0xFF)
        ])
        
        // IFD0 的下一个 IFD 偏移量
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        
        // ExifIFD
        exifData.append(contentsOf: [0x00, 0x01]) // 条目数量
        
        // 0x8897 标签条目
        exifData.append(contentsOf: [0x88, 0x97]) // Tag
        exifData.append(contentsOf: [0x00, 0x01]) // Type: BYTE
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // Count: 1
        exifData.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // Value: 1
        
        // ExifIFD 的下一个 IFD 偏移量
        exifData.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        
        return exifData
    }
} 