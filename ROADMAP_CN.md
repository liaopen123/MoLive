# MoLive 路线图

MoLive 的目标不只是“能生成文件”，而是在 iOS 上可靠地迁移、验证和修复 Live Photo / Motion Photo。

## 当前原则

- 原图优先：只在方向、编码或目标设备不兼容时转码。
- 生成后验证：不以“成功写入文件”代替格式正确性检查。
- 本地处理：照片和位置数据默认不离开设备。
- 格式与 UI 分离：转换内核可独立测试，不依赖 SwiftUI 和相册界面。

## P0：转换正确性

- [x] 将图片 EXIF Orientation 烘焙到像素。
- [x] 将视频 `preferredTransform` 烘焙到视频帧。
- [x] 保留 JPEG EOI，生成“完整 JPEG + MP4”。
- [x] 消除 Live Photo 多资源并发写入同一文件的竞态。
- [x] 将 Live Photo 的 `com.apple.quicktime.still-image-time` 写入配对视频。
- [x] 从原 Live Photo 读取展示帧时间，写入 `MicroVideoPresentationTimestampUs`。
- [x] Motion Photo 反向转换时保留视频音轨。
- [x] 按 XMP offset 分离视频，JPEG EOI / ISO BMFF box 扫描仅作降级方案。
- [x] 生成较新的 Google Motion Photo Container XMP，同时保留 GCamera 兼容字段。
- [x] 实现生成后验证器：JPEG、XMP、offset、MP4 box、时长、音轨和展示帧。

## P1：稳定性与批量迁移

- [x] 缓存清理仅删除 MoLive 自己的目录。
- [x] 将 Files 安全范围 URL 立即复制到应用缓存，避免延迟转换时权限失效。
- [x] 正确统计批处理失败数。
- [ ] 将转换状态限定在 `MainActor`，消除 Swift 6 并发警告。
- [ ] 支持取消、暂停、续传、失败重试和 iCloud 下载进度。
- [x] 将转换历史从 `UserDefaults` 迁移到可清理的 JSON 持久化存储。
- [x] 批处理保留原始拍摄时间，并通过转换历史跳过重复输出。
- [ ] 批量导出到 Files、指定相册或局域网设备。

## P2：多设备兼容与修复

- [ ] 提供小米 / Pixel / 三星 / 通用 Android 输出预设。
- [x] 仅当方向需烘焙或视频/音频编码不兼容时转码，其余流直接复用。
- [ ] 完善 Motion Photo 修复器（已支持恢复 MoLive 旧版缺失的 JPEG EOI，待补充 XMP/offset/音频修复）。
- [ ] 支持从 Files 批量导入 HEIC/JPEG + MOV，按 Content Identifier 自动配对。
- [ ] 支持文件名和拍摄日期降级配对，并显示配对置信度。
- [ ] 允许用户选择展示帧并同步更新静态图和时间元数据。

## P3：HDR 与系统集成

- [ ] 识别 Apple HDR Gain Map，保留 Display P3 和原始 HDR 信息。
- [ ] 将 Apple HDR HEIC 转换为 Android Ultra HDR JPEG Motion Photo。
- [ ] 增加 Share Extension，从系统相册直接转换。
- [ ] 增加 App Intents / 快捷指令。
- [ ] 增加元数据隐私开关：GPS、设备型号、拍摄时间。

## 参考项目的经验吸收

### LivePhotoBridge

- 按 Apple Content Identifier 配对图片和视频。
- 根据 `LivePhotoVideoIndex / RunTimeScale` 计算展示帧时间。
- 针对缺失 Content Identifier 的资源，使用文件名和日期降级配对。

### LivePhoto2XiaomiPhoto

- 保留小米识别所需的 MVIMG / `0x8897` 与 GCamera XMP 兼容策略。
- 检测音频编码，仅在必要时转 AAC。
- 该项目未提供许可证，只吸收格式与兼容性经验，不复制其代码。

### Apple-photo-to-UltraHDR-motion-photo

- 借鉴 Apple HDR Gain Map 到 Android Ultra HDR Gain Map 的映射流程。
- 借鉴方向预处理、AAC 兼容和生成后验证思路。
- 该项目为 Apache-2.0，若后续移植算法，需保留必要的版权与 NOTICE 信息。

## 发布门槛

V1 发布前至少需要通过以下样本矩阵：

- EXIF Orientation 1–8。
- 前置/后置摄像头，横屏/竖屏/180°。
- HEVC/H.264，AAC/非 AAC/无音频。
- iCloud 本地原片与需下载原片。
- 小米 HyperOS、Google Photos 和三星相册实机识别。
- 原图、编辑后 Live Photo、从 macOS/Files 导入的配对资源。
