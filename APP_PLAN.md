# 离线双方知情声明记录 App（iOS MVP）实施规划

## 总览

- 以 Xcode 26.6、Swift 6.3.3 编译器、Swift 6 语言模式、SwiftUI 构建，支持 iPhone 与 iPad（最低 iOS 17.0）；iPad 支持四方向与多任务窗口，录制成片保持固定竖屏画幅以确保画面和水印一致。
- 产品定位为“帮助伴侣当面表达、彼此确认并各自保存的本地加密记录工具”，界面不使用法律结论式或恐吓式提示。
- 所有用户可见界面文字使用同一份字符串目录维护简体中文、英语、日语三种语言；每次增删或修改文案必须同步更新三种语言。
- 无账号、无开发者服务器、无分析/广告/崩溃上报 SDK、无系统相册写入。双机只用本地 Multipeer Connectivity；iCloud Drive 通过用户主动选择的系统“文件”保存器导出，意味着文件会交给 Apple iCloud，而不会传给开发者。
- 第一版以本地开发签名、两台真机 iPhone 验收为目标。未来 App Store 发布须先完成法律审查和审核预评估；Apple 当前对露骨性内容及以性关系为核心的应用存在明显审核风险。[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## 产品流程与界面

- 首次启动依次展示：温和的本地隐私介绍、成年与合法使用确认、私密空间密码设置、可选提示词、姓名与头像设置、保存方式选择。
  - 新建密码至少 8 位，只能包含数字或英文字母；提示词最多 60 字，明确提示它不是密码且可能泄露线索。
  - 不存储明文密码；忘记密码无法恢复，只能显示提示词。重置 App 私密空间只清除本机配置，不能删除已导出的 iCloud 文件。
  - 头像使用系统 `PhotosPicker` 选择，不请求照片库读取权限；姓名、头像只保存在本机加密设置中。
  - 首页突出“开始一份新记录”，双机保存标记为更安心；另提供“打开一份私密记录”“资料与隐私”“删除待导出草稿”。

- 录制前的固定说明为：

  > 我叫【本人姓名】，我已经成年，我同意并自愿与【对方姓名】发生性关系，我意识清醒，没有受到任何形式的胁迫。

  该文案为固定声明，除将【本人姓名】和【对方姓名】替换为实际姓名外，不得增删或改写。

  每位参与者必须在自己的告知页勾选理解并亲自点击“开始录制”；不提供静默、后台、远程或他人代启动录制。

- 同机保存模式：
  - 创建会话后依次录制 A、B 两段；每段使用前置摄像头、麦克风、3 秒倒计时、明显的红色 `REC` 状态和剩余时间。
  - 每段最长 30 秒，可手动结束；达到上限自动结束。无录后预览确认，B 段结束后直接合成、加密并打开系统文件保存器。
  - 成片固定按 A → B 拼接；不保留两段原片，也不写入系统相册。

- 双机保存模式：
  - A 展示二维码，B 扫描；二维码仅含协议版本、会话 ID、一次性随机数和 A 的临时公钥。
  - 双方以本地网络/点对点 Wi-Fi/蓝牙建立 `MCSession`，交换本地姓名、头像和六位短验证码；双方确认“资料正确且验证码一致”后才能录制。Multipeer Connectivity 本身支持这些近距离传输方式，并需要本地网络用途说明。[Apple Multipeer Connectivity 文档](https://developer.apple.com/documentation/multipeerconnectivity)
  - 两台手机同时倒计时、分别录制自己的 30 秒声明。两段完成后，各自先加密传输自己的片段给对方，再各自在本机按 A → B 合成。
  - 两台手机分别选择“私密空间密码”或“本次一次性密码”加密自己的最终包，并各自使用系统文件保存器保存到自己的 iCloud Drive。两份包可采用不同密码。
  - 配对或传输中断时，已录制片段仅以本机私密空间密钥加密暂存 10 分钟，允许重新扫码配对；超时、明确取消或失败则删除暂存并要求重新录制。

- 录制成片实时烧录水印：本机本地日期时间、短会话 ID、A/B 角色和录制状态。界面将水印描述为便于整理和回看的信息，不作身份认证或法律结论式承诺。
- 导出完成后删除本机原始与合成明文；成功导出的加密包默认不在 App 内保留副本。若用户在“文件”保存器取消，则只保留加密待导出包供重试或手动删除。
- 解锁查看时从“文件”导入 `.xagree` 包，输入其密码后仅生成受保护的临时播放文件；停止播放、锁屏、切后台或 60 秒无操作即删除。App 切后台时立即遮蔽界面。iOS 闪存不提供可验证的安全擦除保证，隐私说明不能承诺“彻底物理擦除”。

## 架构、接口与安全设计

- 将现有空工程改为 iPhone/iPad App，替换模板化 App 入口与 Bundle ID 占位符；在 `ContentView.swift` 外建立分层的 SwiftUI 功能目录，并将 `___App.swift` 重命名为有效的 `XAgreeApp` 入口。
- 不引入第三方依赖；使用 SwiftUI、Observation、AVFoundation、CryptoKit、Security、MultipeerConnectivity、CoreImage、UniformTypeIdentifiers、PhotosUI。

```swift
protocol CaptureRecording {
    func requestAccess() async -> CaptureAuthorization
    func begin(_ request: CaptureRequest) async throws
    func stop() async throws -> CaptureArtifact
    func cancelAndDelete()
}

protocol EvidenceCrypting {
    func seal(video: URL, manifest: EvidenceManifest,
              protection: PasswordProtection) async throws -> URL
    func open(package: URL, password: String) async throws -> DecryptedEvidence
}

protocol NearbyPeerTransport {
    func host(_ invitation: PairingInvitation) async throws
    func join(scanned invitation: PairingInvitation) async throws
    func confirmPairing() async throws
    func sendEncryptedResource(_ artifact: URL) async throws -> TransferReceipt
}
```

- 核心状态模型：`VaultState`、`SessionMode`、`ParticipantRole`、`SessionState`、`ParticipantProfileSnapshot`、`CaptureArtifact`、`EvidenceManifest`、`PasswordProtection`、`PairingInvitation`、`PeerWireMessage`。
  - `SessionState` 仅允许 `.draft → .paired/.armed → .recording → .transferring → .assembling → .encrypting → .awaitingExport → .completed` 的合法迁移；取消、权限拒绝、存储不足和篡改均进入失败分支并清理明文。
  - 资料快照包含自填姓名和归一化头像 SHA-256，不保存或声称验证真实身份；之后修改资料不影响既有会话。

- `CaptureService` 用 `AVCaptureVideoDataOutput`、`AVCaptureAudioDataOutput` 与 `AVAssetWriter` 直接写入 H.264/AAC MP4。`WatermarkRenderer` 在每一个视频帧写入水印，预览层不是唯一水印来源；录制设置为 1080p、30fps、前摄像头、未镜像成片。
- `MediaAssembler` 使用 `AVMutableComposition` 合并 A/B，输出单个 MP4；合成前检查时长、音视频轨、文件大小和每段 SHA-256。
- 加密包定义为版本化 `.xagree` 容器：明文头仅含魔数、格式版本、KDF 参数、随机盐、分块数量及随机 nonce 前缀；其余清单和 MP4 均加密。
  - 每个包生成随机 256-bit 内容密钥；视频按 1 MiB 分块使用 AES-256-GCM 加密，每块唯一 nonce，头部作为附加认证数据。
  - 密码通过 CommonCrypto `PBKDF2-HMAC-SHA512`、32-byte 随机盐和设备校准后的固定最低工作时长派生包装密钥；只保存每个文件所需的盐、轮数和密文，不保存密码或可逆密码校验值。
  - `EvidenceManifest` 加密保存会话 ID、模式、A/B 顺序、时间、水印参数、资料快照、片段与成片哈希、软件/格式版本；不写入设备标识符、位置或联网数据。
  - 所有工作文件设置 `NSFileProtectionComplete` 并排除系统备份；密码只存在内存，禁止日志、剪贴板、崩溃报告和分析事件。

- `PeerSessionCoordinator` 用临时 X25519 (`Curve25519.KeyAgreement`) 协商共享密钥，并用 HKDF 派生传输密钥；二维码公钥、双向挑战和六位短验证码共同抵抗错误配对/中间人。
  - 传输前先用 AES-GCM 分块加密片段，再以 `MCSession.sendResource` 发送；接收端验证长度、认证标签和 SHA-256 后才参与合成。
  - 不建立 URLSession、WebSocket、云数据库或开发者域名请求；仅在用户保存时由系统 Files UI 写入其选择的 iCloud Drive 位置。[UIDocumentPicker 导出行为](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller)
  - `Info.plist` 配置相机、麦克风、本地网络用途说明及 Multipeer 对应 Bonjour 服务；不申请照片库权限。相机和麦克风权限缺失时不得初始化采集会话。[Apple 媒体权限说明](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)

## 验证计划

- 单元测试：密码加密往返、错误密码、任意密文/头部/分块篡改、重复 nonce 防护、清单哈希校验、导入旧格式拒绝、所有状态机非法迁移、30 秒上限、文件清理和无日志泄密。
- UI 测试：首次配置、提示词、每人独立启动、权限拒绝与跳转设置、低存储空间、取消录制、导出取消/重试、后台遮蔽、密码遗忘与导入解锁。
- 两台真机集成测试：二维码配对、双方资料/验证码确认、同步录制、Wi-Fi 与蓝牙可用路径、无外网局域网传输、连接中断后 10 分钟内恢复、验证码不匹配/对方拒绝/文件哈希不匹配。
- 媒体与导出验收：成片 A→B 顺序、音画同步、全帧水印、每段最多 30 秒、无相册副本、iCloud Drive 中仅有不可播放的 `.xagree` 文件、正确密码可播放且错误密码不可获取任何清单或视频。
- 发布前进行独立安全审查、所在地律师审查、真机隐私权限审查，以及 App Store 审核预沟通；商店文案避用“防诬告”“法律证明”等承诺。

## 已锁定的默认决策

- 本地开发版优先；两台不同 Apple ID 的 iPhone 真机为验收基线。
- 用户主动选择 iCloud Drive 保存位置，不使用应用私有 iCloud 容器。
- 双机模式各自独立加密、各自保存；双机同时录制，最终固定 A→B。
- 有声音、单条水印成片、不保留原片；无录后预览确认。
- 密码不可找回；资料自填且仅以会话快照使用；每位参与者必须亲自启动自己的录制。
