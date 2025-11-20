# NetSpeed

🇨🇳 中文 | [🇬🇧 English](README_EN.md)

极简而强大的 macOS 状态栏网速显示小工具，支持动态更新频率、开机启动与多种网速显示模式。

## 👀 效果预览
![NetSpeed Preview](./Sources/Assets/ScreenShot_1.png)
![NetSpeed Preview](./Sources/Assets/ScreenShot_2.png)

## ✨ 功能特性
- **实时网速** 主网络接口上行/下行速率，单位自动切换（B/s、KB/s、MB/s）
- **动态更新** MB 级高速时 0.5 s 刷新，低速时 1 s
- **图标开关** 可选择显示箭头指示符
- **开机启动** 一键设置开机启动
- **零依赖** 纯 Swift + 系统框架，无第三方库，体积 < 100 KB
- **低功耗** CPU 占用率极低，仅有 0.2% 左右

## 🚀 快速开始
```bash
# 克隆 & 构建
git clone https://github.com/Tespera/NetSpeed.git
cd NetSpeed
swift build -c release

# 构建完打包成 app
./tools/package_app.sh
# 将打包好的 NetSpeed.app 拖到到 /Applications 安装后打开即可
```

## 🛠️ 手动安装
1. 下载 [最新 Release](https://github.com/Tespera/NetSpeed/releases)
2. 解压后将 `NetSpeed.app` 拖入 `/Applications`
3. 首次运行 → 系统设置 → 隐私与安全 → 允许
4. 状态栏图标 → 右键 → Launch at Login（如需开机启动）

## 🎛️ 使用说明
| 功能 | 操作 |
|---|---|
| 显示/隐藏图标 | 状态栏图标 → Show Icons |
| 切换上行/下行 | 状态栏图标 → Upload Only / Download Only / Both |
| 开机启动 | 状态栏图标 → Launch at Login |
| 退出应用 | 状态栏图标 → Quit |

## 📊 网速计算
- **数据来源**：SystemConfiguration 框架获取当前主接口（Wi-Fi / Ethernet）
- **平滑窗口**：MB 级无平滑，< 1 MB/s 时 3 点滑动平均，兼顾灵敏与稳定
- **单位进制**：1 KB = 1000 B，1 MB = 1000 KB，与 Safari 活动监视器保持一致

## 🖥️ 系统要求
- macOS 11 Big Sur 及以上
- Apple Silicon & Intel 双架构

## 📝 构建开发
```bash
swift build                     # 调试构建
swift run                       # 直接运行
swift test                      # 运行测试（如有）
```

## 🤝 贡献
欢迎 Issue & Pull Request！请遵循 Swift 官方风格，保持零依赖。

## 📄 许可证
MIT © 2025 Tespera

---
如果 NetSpeed 帮到了你，给颗 ⭐ 就是最大的支持！