# UpTop

UpTop 是一个**非常轻量的 macOS 菜单栏监控工具**，显示 CPU 占用率、CPU 温度、GPU 占用率和实时网速。在 Apple M5 上构建的完整应用仅占约 **170 KB** 磁盘空间。

![UpTop 菜单栏截图，显示 CPU 占用率、CPU 温度、GPU 占用率及上传下载速度](docs/screenshot.png)

- 上传和下载速度叠在同一列，节省菜单栏空间。
- 点击菜单栏项目可勾选显示内容，选项会在重启后保留。全部取消时，保留一个波形按钮。
- 使用 Swift、AppKit 和 IOKit，无第三方运行时依赖。

## 构建与运行

需要 macOS 14 或更新版本，以及带 Swift 工具链的 Xcode 或 Command Line Tools。

```sh
git clone https://github.com/lmwacn/UpTop.git
cd UpTop
./build.sh
open UpTop.app
```

构建脚本会生成当前 Mac 架构的应用，并执行本地签名。温度和 GPU 占用率依赖硬件公开的传感器及驱动统计。读不到时显示「—」。这两项已在 Apple M5 上验证。

AppleSMC 温度读取参考了 [AirStats](https://github.com/byrencheema/airstats)。项目采用 [MIT 许可证](LICENSE)。
