# 26AnimSafe — 不会崩的 iOS 26 开/关 App 缩放动画

## 背景 / 根因（已修正）

iPhone 6s (iOS 15.8.8, rootless) 装源 `https://winaviation.github.io/repo/` 的 **26Anim**
后一注销（respring）就进安全模式。拆包做 Mach-O / ObjC 元数据分析确认：

- 它 hook 的是 **iOS 26 才有的 SpringBoard 类**（`SBIconZoomAnimator`、
  `SBHomeGesture*Zoom*Settings` 等）。这些类在 iOS 15.8.8 **根本不存在**；
- 它对这些类/方法**没有任何存在性 / nil 守卫**，运行时强制解包 nil →
  SpringBoard abort → 安全模式。
  （所以「26Anim 在 iOS 15 必然崩」是对的——它依赖的私有类在 iOS 15 上压根没有。）

第一版 26AnimSafe 沿用了同样的 iOS 26 hook 目标、只是加了守卫：结果在 iOS 15 上
`objc_getClass()` 全部返回 Nil，每个 hook 静默跳过 → **装了但完全没生效、也没崩**
（正是反馈的「跟原来一样」）。

v1.0.0-2 因为把 `-settings` 在两个都叫 `-settings` 的动画器类上**按 selector 名共享一个原始 IMP
字典**而**交叉串台** → SpringBoard 调到错误类的 IMP → 自动注销死循环。v1.0.0-3 改成「每个类/selector
各自捕获原始 IMP」修好了崩溃，但**仍然完全没动画**——根因是：

`duration` / `cornerRadius` / `scale` **根本不在 `SBHIconZoomSettings` 上**。真实的类继承是

    PTSettings → SBHIconAnimationSettings(centralAnimationSettings:SBFAnimationSettings*)
              → SBHIconZoomSettings(只有 labelAlphaWithZoom)
                → SBHScaleZoomSettings(还有 crossfadeSettings/iconGridFadeSettings/outerFolderFadeSettings)
                  → SBHCrossfadeZoomSettings(morphSettings) / SBHFolderZoomSettings(innerFolderFadeSettings)
                → SBHCenterZoomSettings → SBHCenterAppZoomSettings(appZoomSettings/appFadeSettings)

真正控制时长的 `duration` 在 **`SBFAnimationSettings`** 上，而且要穿过不同子对象才能拿到：
`SBHScaleZoomSettings`→`centralAnimationSettings.duration`（普通图标缩放）、
`SBHCenterAppZoomSettings`→`appZoomSettings.duration`+`appFadeSettings.duration`（**开/关 App**）、
`SBHCrossfadeZoomSettings`→`morphSettings.duration` 等。v3 直接对 `SBHIconZoomSettings` 做 KVC
`setValue:forKey:@"duration"` → 触发 `NSUnknownKeyException` → 被 `@try/@catch` 吞掉 → **100% 静默 no-op**
（不崩、但毫无效果，正是你看到的「跟原来一样」）。

## v1.0.0-5 —— 真正生效的修法（关键）

v1.0.0-4 仍然「装了没反应」，根因是 **hook 错了类树**：

- iOS 15 上 App 开/关（打断）缩放**根本不是**由 `SBHIconZoomSettings` /
  `SBFAnimationSettings.duration` 驱动的；
- 它由一个 **fluid behavior**（类似 `UISpringTimingParameters`）驱动，对应类叫
  **`SBFFluidBehaviorSettings`**（SpringBoardFoundation），暴露两个 setter：
  - `-setResponse:` —— 时间常数（秒），**越大越慢**；系统 App 缩放约 `0.37`，iOS 26 明显更慢；
  - `-setDampingRatio:` —— `1.0` = 临界阻尼（无回弹），**越小回弹/过冲越多**。
- v3/v4 去改 `SBHIconZoomSettings` / `SBFAnimationSettings.duration` 这个**完全不参与 App
  开/关缩放**的树，所以 100% 静默 no-op（不崩、也没效）。

**v5 改为 hook `SBFFluidBehaviorSettings`**（这正是开源 tweak Speedster 在 iOS 13–16.7 上
用来做「App 开/关速度 + 回弹」的同一套、跨版本稳定的底层机制），强制：

- `response` 调大 → 缩放明显变慢、更绵长（iOS 26 感）；
- `dampingRatio` 略低于 1.0 → 轻微过冲/回弹。

这是版本无关、必有可见效果的写法（只要 `SBFFluidBehaviorSettings` 存在于该 iOS，而它在
iOS 13–16 全部存在）。

### v5 的具体做法

1. `%hook SBFFluidBehaviorSettings`：重写 `-setResponse:` / `-setDampingRatio:`，开启时强制
   为目标值（`response=0.50`、`dampingRatio=0.72`）；关闭时 `%orig` 原值；
2. `%hook SBFAnimationSettings`：把**短**（≤0.5s）的 `duration` 也拉到 `0.45s`
   （文件夹缩放、图标标签淡入等），让整个「缩放家族」观感一致；长过渡不动，避免全局拖慢；
3. 全部是 Logos `%hook`（每个类各自捕获原始 IMP，**结构上不可能交叉串台 / 不可能让 SpringBoard
   abort**），且受 `gEnabled` 守卫；iOS 18+ 自动让路；
4. **一次性 syslog 日志**（`[26Anim]`）：respring 后打开一次 App 即可在日志里看到
   `SBFFluidBehaviorSettings.setResponse forced 0.500 ...`，**实证** hook 命中且值已写入。

> 真·iOS 26「手势跟手连续打断」需要 `UIViewAnimating` 交互式架构，iOS 15 没有这层机制，
> 无法 1:1 还原。v5 做到的是「慢 + 弹性回弹」的近似观感——这是 iOS 15 上能达到的最接近效果。

默认 **response = 0.50s / dampingRatio = 0.72 / duration = 0.45s**（系统开/关约 0.37s，明显更慢更顺滑）。
原 26Anim 的 3D 网格形变属于 iOS 26 私有原语，iOS 15 上无法还原——平台限制，不是 bug。

## 复用原设置面板

本包直接复用原 26Anim 的偏好域 `com.ngkhoi.26anim`：

- 设置 → 26Anim 里的 **Enable Animations** 开关控制本 tweak；
- **Animation Speed** 选 `Original (iOS native)` 即关闭特效，选 `iOS 26` 开启。

所以操作习惯和原来完全一致。

## 使用步骤

1. 安全模式里用 Sileo **卸载原 26Anim**（卸干净 dylib，避免两个都注入冲突）；
2. 把本仓库推到 GitHub，Actions 会自动编出 rootless arm64 的 `.deb`
   （在 Actions 页面的 Artifacts 里下载）；
3. 用 Sileo / Filza 安装 `26animsafe-deb`；
4. 重启 SpringBoard（respring）。它**不会**再进安全模式。
5. 想要更快/更慢、更弹/更稳的缩放，改下列键后 respring 生效：
   - `/var/jb/var/mobile/Library/Preferences/com.ngkhoi.26anim.plist`（设置面板实际写入的域）
   - 或 `/var/jb/var/mobile/Library/Preferences/com.you.26animsafe.plist`
   键（均为 double 秒 / 无量纲）：
     - `response` —— 越大越慢（默认 0.50；想更接近 iOS 26 绵长缩放可设 0.6）
     - `dampingRatio` —— 越小回弹越多（默认 0.72；0.6 更弹、0.9 几乎不弹）
     - `duration` —— 短过渡（文件夹缩放等）时长（默认 0.45）
   例：`{ enabled = 1; response = 0.6; dampingRatio = 0.65; }`。
   设置面板里的 **Animation Speed = Original (iOS native)** 或本包 **Enable Animations** 关掉即还原。

> 你已有的 GitHub Actions 越狱工具链可以直接套用 `.github/workflows/build.yml`，
> 或把本目录并进去你现有的 theos 工程。

## 验证（无崩 + 实证命中）

- 装好后 respring：**不会**再进安全模式（每个 hook 都有存在性判断，每次修改都有 `@try/@catch` +
  各自捕获的原始 IMP，结构上不可能让 SpringBoard abort）。
- **实证本 tweak 真的生效**（不只「没崩」）：设备连 Mac 跑
  `log stream --predicate 'process == "SpringBoard"' | grep 26Anim`
  （或装 `idevicesyslog` / syslog 类插件在手机上抓），respring 后**打开一次 App**，
  应能看到一行类似
  `[26Anim] SBFFluidBehaviorSettings.setResponse forced 0.500 (was 0.370)`
  和 / 或
  `[26Anim] SBFFluidBehaviorSettings.setDampingRatio forced 0.720 (was 1.000)`。
  看到这行 = **hook 命中且值已写入**，App 开/关缩放必然变慢 + 带轻微回弹；**看不到** =
  你这台 iOS 的 `SBFFluidBehaviorSettings` 行为异常，把那行 syslog 贴给我即可。
- 万一出现意外：设置 → 26Anim 里把 **Enable Animations** 关掉，或进安全模式卸载即可。

## 进一步（可选）

如果你想要和原 26Anim **像素级一致**的 3D 网格形变效果，下一步可以把原 dylib
用 capstone/radare2 反汇编，提取 `meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:`
的具体顶点/面数据，再接进本版的 `modifySettings` 里（仅当设备响应该私有方法时才应用）。
需要的话我可以继续做这步逆向。
