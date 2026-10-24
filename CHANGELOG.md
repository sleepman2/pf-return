# Changelog

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.0] - 2026-10-24

### 新增

- **UDP 支持**：白名单条目可带协议后缀 `53/udp`、`6000/both`
- 交互式菜单增加协议选择（默认 `tcp`）
- 脚本支持 `--version`
- 英文文档 `README.en.md`
- `test/smoke.sh`：在独立 netns 中验证增删逻辑，不触碰宿主网络
- 开源项目文件：`LICENSE`（MIT）、`SECURITY.md`、`CHANGELOG.md`
- GitHub Actions 工作流（语法检查 + ShellCheck + netns 冒烟测试）
- `.gitignore`

### 修复

- 安装脚本使用 `systemctl enable --now` 时，若服务已是 active 状态，新白名单不会重新下发
- `both` 写法在同步脚本中未展开

### 变更

- 文档示例端口由 `22` 调整为 `8080`，内网网段统一为 `192.168.1.0/24`
- 脚本内兜底默认值改为中性值，避免照搬特定环境
- 删除裸端口时，会同时移除该端口的 TCP 与 UDP 条目

## [1.0.0] - 2026-10-24

### 新增

- 首次发布
- 端口白名单管理（交互式菜单）
- 策略路由 + iptables 标记规则同步
- systemd 开机自启
- 安装 / 卸载脚本
