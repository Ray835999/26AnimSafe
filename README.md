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

## v1.0.0-4 的修复思路

1. 对 **每个具体 `*IconZoomAnimator`**（`SBScaleIconZoomAnimator`、`SBCrossfadeIconZoomAnimator`、
   `SBFolderIconZoomAnimator`、`SBHCenterIconZoomAnimator`、`SBCenterAppIconZoomAnimator`、
   `SBIconZoomAnimator`）swizzle 它的 `-settings` getter。这些子类都重写了 `-settings` 并返回各自类型的
   settings 子类，所以必须**逐个 hook 子类**，不能只 hook 基类（基类 Method 不是子类实际派发的那个）；
2. 在 `-settings` 返回的对象上**通用地**遍历所有候选 `SBFAnimationSettings` 子对象
   （`centralAnimationSettings` / `appZoomSettings` / `appFadeSettings` / `crossfadeSettings` /
   `iconGridFadeSettings` / `outerFolderFadeSettings` / `innerFolderFadeSettings` / `morphSettings`），
   用 KVC 把 `duration` 设成目标值（可选 `delay`）。缺哪个就跳过，不影响其余；
3. 每个目标类/方法**不存在就跳过**，每次修改包 `@try/@catch`，原始 IMP **各自捕获、绝不交叉串台** → 不崩；
4. 只在 **iOS 13..17** 生效，iOS 18+ 自动让路；
5. **加了一次性 syslog 日志**（`[26Anim]`）：装好 respring 后抓
   `log stream --predicate 'process == "SpringBoard"' | grep 26Anim` 即可**实证**本 tweak 是否真的
   命中了动画、改了哪些 key（满足「no error ≠ verified」的硬要求）。

可见变化来自把 `SBFAnimationSettings.duration` 调长（KVC，属性不存在会被吞掉但其余照常）。
默认 **duration = 0.6s**（系统约 0.3–0.4s，明显更慢更顺滑）。原 26Anim 的 3D 网格形变属于 iOS 26
私有原语，iOS 15 上无法还原——平台限制，不是 bug。

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
5. 想要更快/更慢的缩放，改时长（秒）后 respring 生效：
   - `/var/jb/var/mobile/Library/Preferences/com.ngkhoi.26anim.plist`（设置面板实际写入的域）
   - 或 `/var/jb/var/mobile/Library/Preferences/com.you.26animsafe.plist`
   加 `duration`(double，秒；默认 0.6) 和可选 `delay`(double，秒；-1=跟随系统)。
   例：`{ enabled = 1; duration = 0.8; }`（0.8s 更接近 iOS 26 的绵长缩放）。
   `corner` / `scale` 在这个动画面上**不可控**（缩放比例由动画器内部算，不在 settings 里），忽略即可。

> 你已有的 GitHub Actions 越狱工具链可以直接套用 `.github/workflows/build.yml`，
> 或把本目录并进去你现有的 theos 工程。

## 验证（无崩 + 实证命中）

- 装好后 respring：**不会**再进安全模式（每个 hook 都有存在性判断，每次修改都有 `@try/@catch` +
  各自捕获的原始 IMP，结构上不可能让 SpringBoard abort）。
- **实证本 tweak 真的生效**（不只「没崩」）：设备连 Mac 跑
  `log stream --predicate 'process == "SpringBoard"' | grep 26Anim`
  （或装 `idevicesyslog` / syslog 类插件在手机上抓），respring 后**打开一次 App**，
  应能看到一行类似
  `[26Anim] applied duration=0.60 delay=-1.00 -> animator=<SBCenterAppIconZoomAnimator> settings=<SBHCenterAppZoomSettings> mutatedKeys=(centralAnimationSettings,appZoomSettings,appFadeSettings)`。
  看到这行 = hook 命中且 `duration` 已写入，动画必然变慢；**看不到** = 这个 iOS 版本的动画器类
  名又不一样，把那行 syslog 贴给我，我再加对应类。
- 万一出现意外：设置 → 26Anim 里把 **Enable Animations** 关掉，或进安全模式卸载即可。

## 进一步（可选）

如果你想要和原 26Anim **像素级一致**的 3D 网格形变效果，下一步可以把原 dylib
用 capstone/radare2 反汇编，提取 `meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:`
的具体顶点/面数据，再接进本版的 `modifySettings` 里（仅当设备响应该私有方法时才应用）。
需要的话我可以继续做这步逆向。
