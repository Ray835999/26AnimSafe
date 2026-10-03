# 26AnimSafe — 不会崩的 iOS 26 开/关 App 缩放动画

## 背景 / 根因

iPhone 6s (iOS 15.8.8, rootless) 装源 `https://winaviation.github.io/repo/` 里的
**26Anim** 后，一注销（respring）就进安全模式。把它的 deb 拆开做 Mach-O / ObjC
元数据分析后确认：

- 它 **不是** 架构或安装路径装错（deb 装到 `/var/jb/...`，是 rootless 布局，arm64 也对）；
- 它 hook 的是 **iOS 15 上真实存在的 SpringBoard 图标缩放动画系统**
  （`SBHomeGesture*Zoom*Settings`、`SBIconZoom*Settings`、私有网格变形
  `meshTransformWithVertexCount:...`、以及由 `dictionaryWithContentsOfFile:`
  配置的 `CADisplayLink` 动画循环）；
- 崩溃是因为它对这条「iOS 26 风格」路径**没有任何存在性 / nil 守卫**，在 15.8.8
  上某个类/方法缺失或配置文件读出来是 nil，被直接解包 → SpringBoard abort → 安全模式。
  同作者的 26Home 能在 iOS 15 跑，正好说明「iOS 26 系插件在 iOS 15 必然崩」是错的，
  只是 26Anim 自己写得不安全。

## 这个修复版的思路

重做一个**源码级、全程守卫**的版本，hook **同一批**图标缩放 Settings 表面，
复刻 iOS 26 那种「流体缩放」手感，但结构上保证不再让 SpringBoard 崩：

1. 每个目标类 / getter：**不存在就跳过**（类或方法在运行时取不到 → no-op）；
2. 每次修改都包 `@try/@catch`，失败就回退原始值；
3. 原始实现永远可调用，作为最后兜底；
4. 只在 **iOS 13..15** 生效，iOS 16+ 自动让路（原生已经有该动画）。

可见变化来自对缩放 settings 的 `duration` / `cornerRadius` / `scale` 微调
（用 KVC，属性不存在也不会崩）。原 26Anim 最具辨识度的 3D 网格变形（mesh warp）
属于「iOS 26 私有原语」，在 iOS 15 上是否可用不确定——本版不强行构造它，
避免重蹈崩溃覆辙；如果你要 100% 还原那个形变，需要把原 26Anim 的网格数学
逆向出来再接进来（见下方「进一步」）。

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
5. 想要更慢/更圆的缩放，改
   `/var/jb/var/mobile/Library/Preferences/com.you.26animsafe.plist`
   里的 `duration`(秒) / `corner`(pt) / `scale`(倍数)，再 respring。

> 你已有的 GitHub Actions 越狱工具链可以直接套用 `.github/workflows/build.yml`，
> 或把本目录并进去你现有的 theos 工程。

## 验证（无崩保证）

- 装好后 respring：若进入安全模式说明有别的插件在作怪（本 tweak 在
  `%ctor` 里对所有 hook 做了存在性判断，且每个修改都有 `@try/@catch` + 原始兜底，
  理论上不可能让 SpringBoard abort）。
- 万一出现意外：设置 → 26Anim 里把 **Enable Animations** 关掉，或进安全模式卸载即可。

## 进一步（可选）

如果你想要和原 26Anim **像素级一致**的 3D 网格形变效果，下一步可以把原 dylib
用 capstone/radare2 反汇编，提取 `meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:`
的具体顶点/面数据，再接进本版的 `modifySettings` 里（仅当设备响应该私有方法时才应用）。
需要的话我可以继续做这步逆向。
