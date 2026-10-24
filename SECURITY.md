# 安全说明

## 运行权限

pf-return 需要 **root** 权限，因为它会：

- 修改 `iptables -t mangle` 的 `OUTPUT` 链
- 新增 `ip rule` 与自定义路由表（默认 `table 100`）
- 安装并启用一个 systemd 服务

所有操作都是**幂等**的，且只影响带 `pf-return` 注释的规则，不会清空或重排你已有的防火墙策略。

## 数据与网络

- 不发起任何网络请求
- 不收集、不上报任何信息
- 无遥测、无自动更新
- 所有配置与规则都在本地文件系统中

## 部署建议

1. 部署前通读 `install.sh`、`payload/pf-return`、`payload/pf-return-sync.sh`（约 300 行）
2. 先在测试机或虚拟机中验证，再上生产网关
3. 注意本工具的用途是**把端口暴露到公网**，暴露面本身的风险需自行评估：
   - 修改默认端口
   - 强制密钥认证 / 强口令
   - 配置访问频率限制
   - 或改用 WireGuard、Tailscale、Cloudflare Tunnel 等隧道方案，不直接暴露端口
4. 定期检查白名单，删除不再需要的端口：

   ```sh
   pf-return -l
   iptables -t mangle -S OUTPUT | grep pf-return
   ```

## 卸载

```sh
sudo ./install.sh --uninstall
```

会移除服务、脚本、iptables 规则、`ip rule` 和路由表，不会残留。

## 报告漏洞

如果你发现安全问题，请**不要**直接开公开 Issue。

请通过以下方式之一联系维护者：

- 在仓库的 Security 页面提交 Private vulnerability report
- 发送邮件至项目维护者（见仓库主页）

请在报告中包含：

- 受影响的版本（`pf-return --version`）
- 复现步骤
- 影响范围评估

我们会在 72 小时内确认收到，并在修复后于 CHANGELOG 中致谢（如你愿意）。
