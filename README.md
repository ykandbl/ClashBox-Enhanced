# ClashBox Enhanced

ClashBox Enhanced 是面向 HarmonyOS NEXT 的 ClashBox 自维护分支。它基于[原项目 ClashBox](https://github.com/xiaobaigroup/ClashBox)，保留原作者与协作者的贡献，并持续维护 VPN 连接、配置兼容和日常使用体验。当前维护者：[BaiLe](https://github.com/ykandbl)。

## 这条分支解决了什么

- **连接更稳**：改善冷启动、快速启停、切换 Wi-Fi/蜂窝、切后台后 VPN 意外断开的情况。
- **消息不再轻易卡住**：修复部分客户端消息长期停在“正在发送”、有上传无响应，以及返回前台后长连接重复重建的问题。
- **节点操作更可靠**：修复偶发“核心待重载”、节点无法切换、启动后页面转圈等问题。
- **订阅更新更安全**：兼容常见订阅格式；下载或校验失败时继续保留上次可用配置；阻止旧失败状态引起频繁更新和重载。
- **测速更清晰**：优化批量节点测试的并发、进度与结果显示，切换页面后仍能跟上正在进行的测试。
- **兼容更多使用场景**：改善安卓兼容容器、Telegram、ChatGPT 等长连接应用，以及纯蜂窝网络下的代理体验。
- **诊断与回归**：内置运行诊断，并为核心版本、VPN 生命周期、订阅、节点测试和连接稳定性保留自动化检查。

版本沿革见[RELEASE_HISTORY.md](RELEASE_HISTORY.md)。`2.0.0` 起是本分支的自维护版本；原项目可追溯的版本基线是 `1.7.4`。

## 下载与安装

本仓库的 GitHub Releases 只发布**未签名 HAP**。下载后需要用自己的 HarmonyOS 签名材料和安装工具签名，再安装到自己的设备。这里不分发维护者的签名、开发者认证文件、订阅或账号数据。设备上的签名身份与已有安装包不同，系统可能要求先处理旧安装和数据迁移；请先备份自己的配置。

## 从源码构建

开发环境需要 DevEco Studio、HarmonyOS SDK、Hvigor/ohpm，以及与项目匹配的 ARM64 工具链。运行：

```bash
git clone --recurse-submodules https://github.com/ykandbl/ClashBox-Enhanced.git
cd ClashBox-Enhanced
./scripts/build-public-unsigned.sh
```

脚本先安装各模块依赖；若仓库中没有 native 核心二进制，就自动按锁定版本构建核心；随后使用不含任何私有签名资料的 `build-profile.public.json5`，产出 `entry/build/release/outputs/default/entry-default-unsigned.hap`。若当前目录已有本地 `build-profile.json5`，脚本会保留该文件；本地私有配置始终不进入 Git。需要手动重建 native 核心时，先按[核心维护文档](proxy_core/CORE_MAINTENANCE.md)固定版本和补丁，再运行 `proxy_core/src/flclash/build.sh` 与 `verify-core-ohos.sh`。

发布前运行：

```bash
node scripts/test-p0-regression.cjs
node scripts/test-bitz-subscription.cjs
node scripts/verify-stability-invariants.cjs
node scripts/test-rpc-socket-lifecycle.cjs
```

## 致谢与来源

本分支继承原 ClashBox 的 HarmonyOS UI 和长期支持工作，也使用 [mihomo](https://github.com/MetaCubeX/mihomo)、[FlClash](https://github.com/chen08209/FlClash) 的设计与实现，以及其他依赖项目。应用“关于 → 协作者名单”保留原贡献者，第三方组件的许可证仍在各自目录或资源中。这里对原项目的介绍不代表原作者为本分支提供支持。
