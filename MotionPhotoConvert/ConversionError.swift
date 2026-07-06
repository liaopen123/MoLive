import Foundation

enum ConversionError: LocalizedError {
    case invalidInput
    case conversionFailed
    case frameExtractionFailed
    case videoCreationFailed
    case xmpParsingError(String)
    case noPermission

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "输入文件不是有效的 Live Photo 或 Motion Photo"
        case .conversionFailed:
            return "转换失败"
        case .frameExtractionFailed:
            return "无法提取展示帧"
        case .videoCreationFailed:
            return "无法创建兼容的视频"
        case .xmpParsingError(let message):
            return "XMP 元数据错误：\(message)"
        case .noPermission:
            return "没有照片库访问权限"
        }
    }
}
