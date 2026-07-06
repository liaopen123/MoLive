import Foundation
import Photos
import UIKit

class MotionJPEGToLiveConverter {
    static let shared = MotionJPEGToLiveConverter()
    private init() {}
    
    func convert(from url: URL) async throws {
        // 检查权限状态
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        
        if status != .authorized && status != .limited {
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if newStatus != .authorized && newStatus != .limited {
                throw ConversionError.noPermission
            }
        }
        
        // 转换并保存
        _ = try await Converter.shared.convertMotionJPEGToLivePhoto(from: url)
    }
}
