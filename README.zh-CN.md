# Switch（NicoKam 分支）

[English](README.md)

基于 [Sanyam-G/switch](https://github.com/Sanyam-G/switch) 的 macOS 窗口切换器，加入三指触控板导航和英文／简体中文界面。**克隆本仓库的 `main` 分支即可同时获得这两项功能，无需分别构建功能分支。**

这是独立维护、由 AI 辅助开发的 fork。上游作者明确不合并 AI 生成的 PR，因此相关修改在本仓库维护和发布，不代表官方版本。原项目、网站和版权仍归功于 Sanyam Garg。

## 相对上游的修改

| 功能 | 本仓库的修改 |
| --- | --- |
| 三指导航 | 三指水平滑动唤起窗口选择器，随后左右／上下移动选择窗口，抬起手指完成切换，Esc 取消。 |
| 手势自愈 | 按设备监测触摸帧，睡眠唤醒后重发现，清理陈旧手势，隔离旧回调，并延迟退役设备；提供诊断日志。 |
| 宫格布局 | 可根据显示器宽度自动选择列数，并修复宫格导航及选择器显示位置。 |
| 国际化 | 设置、菜单栏菜单和关于窗口支持跟随系统、英文、简体中文，切换语言后直接刷新这些界面。 |
| 本地构建 | 提供命令行脚本，直接从源码构建，打包翻译及图标并进行临时签名，无需上游的发布证书。 |
| 更新方式 | 手动拉取本仓库并构建，关闭官方 Sparkle 更新源，避免被不包含这些功能的官方二进制覆盖。 |

当前上游基线为 **v0.3.17**，提交 [`4cffdf7`](https://github.com/Sanyam-G/switch/commit/4cffdf72f233603663b50e6c0d709e118aacf9bc)。`main` 已整合原三指手势分支、国际化分支和后续生命周期修复。

## 从源码构建

需要 **macOS 14+**、Apple Command Line Tools、Git 和 Python 3。支持 Apple Silicon 和 Intel，产物架构由实际运行的编译器决定。以下构建方式无需完整 Xcode、Homebrew、XcodeGen、Developer ID 证书或下载 Sparkle。

如果尚未安装 Apple 命令行工具，先执行并完成安装：

```sh
xcode-select --install
```

然后执行：

```sh
git clone --branch main https://github.com/NicoKam/switch.git
cd switch
python3 Tests/Regression/run.py
python3 scripts/build-local.py
```

产物为 **`build/local/Switch.app`**。脚本编译源码，检查并打包中英文翻译，生成图标，记录源码提交并验证临时签名。再次构建会将该输出目录中已有的 app 保存为带时间戳的副本，不会自动安装或启动应用。

安装时先退出正在运行的 Switch，再将产物拖到“应用程序”文件夹。本 fork 沿用官方应用名和 bundle identifier，会替换原安装；请只运行一个副本。在系统设置中授予辅助功能权限，开启缩略图时才需要屏幕录制权限。本地构建使用 ad-hoc 临时签名，没有 Apple 公证；如 macOS 提示，请通过正常的系统授权流程打开。重新构建后可能需要重新授予权限。

官方 Homebrew cask 和 DMG **不包含本 fork 的新增能力**。`scripts/release.sh` 是继承的上游发布流程，需要其签名／公证配置；个人使用请运行 `build-local.py`。

### 让 AI 帮你构建

可将下面的指令交给有权限访问你的 Mac 的 AI 编程助手：

> 请克隆 https://github.com/NicoKam/switch.git 的 main 分支，阅读 README.zh-CN.md，确认 macOS 14+、Apple Command Line Tools 和 Python 3 可用。执行 python3 Tests/Regression/run.py 和 python3 scripts/build-local.py，从源码构建同时包含三指导航和国际化的版本，并打包仓库中的英文及简体中文资源。完成后报告测试结果、源码提交、app 产物路径和安装步骤。

## 启用功能

- **三指手势：** 设置 → 切换器 → 行为 → 三指滑动。先水平滑动唤起，再左右／上下导航，抬起手指选择。如果与系统三指 Mission Control、App Exposé 或拖移设置冲突，请关闭对应的系统手势。
- **语言：** 设置 → 外观 → 语言，可选“跟随系统”“English”“简体中文”。当前翻译覆盖设置、菜单栏菜单和关于窗口，部分窗口选择器／首次权限引导文本仍为上游英文。
- **自动列数：** 设置 → 切换器 → 尺寸 → 自动列数。关闭时沿用手动配置的列数。

原有键盘操作仍可使用：⌘-Tab 切换窗口，⌥-` 切换当前应用的窗口，Return 确认，Esc 取消。跨桌面空间、纵向列表、排除规则、保持模式和可选 Vim 导航等上游功能保留。

## 手势日志和已知限制

原始触摸帧依赖 Apple 私有的 MultitouchSupport 框架。它可能静默停止投递，尤其在睡眠唤醒前后。本 fork 提供检测和重建，不承诺从根本上修复框架。每秒检查健康状态，帧停止约 30 秒后按失活处理；连续恢复失败会退避重试。退役设备对象保留进程生命周期的强引用，以规避已观测到的框架拆卸崩溃。

日志位于 **`/tmp/switch-gesture.log`**。报告问题时，请附上关于窗口中的源码提交、macOS 版本、触控板类型、复现步骤和故障前后的相关日志。回归测试使用模拟 MultitouchSupport 库，测试通过不代表所有真实机器上的私有触摸流都能长期稳定。

## 更新和同步上游

用户在没有本地代码修改的情况下，可以执行：

```sh
git switch main
git pull --ff-only origin main
python3 Tests/Regression/run.py
python3 scripts/build-local.py
```

更新前保存本地改动；构建后退出旧应用并安装新产物。应用的更新入口会打开本仓库构建说明，不下载官方二进制。

维护者同步上游时，在临时分支合并、解决冲突并验证，再推送到我们自己的 `main`：

```sh
# 仅首次添加；已有 upstream 时跳过这一行。
git remote add upstream https://github.com/Sanyam-G/switch.git
git fetch upstream
git switch main
git pull --ff-only origin main
git switch -c sync/upstream-YYYY-MM-DD
git merge upstream/main
# 解决冲突，保留手势、翻译、构建脚本、README
# 以及 SwitchForkBuild 更新策略。
python3 Tests/Regression/run.py
python3 scripts/build-local.py
# 另在真实 Mac 上检查手势、睡眠唤醒及中英文界面。
git switch main
git merge --ff-only sync/upstream-YYYY-MM-DD
git push origin main
```

目前没有自动同步任务，上游更新由维护者合并验证。本 fork 的专属问题请提交到[本仓库 Issues](https://github.com/NicoKam/switch/issues)。

## 许可与致谢

保留原项目的 [FSL-1.1-MIT 许可](LICENSE.md) 和版权声明，fork 修改沿用同一许可。当前项目为源码可见项目，不能将现行许可表述为不受限的 MIT。

[原项目](https://github.com/Sanyam-G/switch) · [原作者网站](https://switch-dev.sanyamgarg.com) · [支持原作者](https://www.paypal.com/paypalme/sanyamg0)。

© 2026 Sanyam Garg。本 fork 修改由 NicoKam 维护。
