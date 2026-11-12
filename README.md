中文 | [English](/README.en.md)

# xrayscript 管理脚本 :sparkles:

纯 Shell 编写的 Xray 一键部署与管理脚本，支持 REALITY、XHTTP、SNI 分流、WARP 分流与自定义反代站点。

- **零依赖安装**：一条 `wget` 命令拉起交互式安装向导
- **五种内置配置**：Vision / XHTTP / Trojan / Fallback / SNI
- **图形化菜单**：安装、启停、分享链接、分流、证书全部菜单化操作
- **中英双语**：`i18n/` 目录下的 JSON 驱动，可自行扩展
- **BBR 加速**：首次快速安装默认开启 TCP BBR，也可在菜单中随时开关

## 配置类型

| # | 配置 | 说明 |
| --- | --- | --- |
| 1 | `VLESS + Vision + REALITY` | XTLS Vision 解决 TLS in TLS |
| 2 | `VLESS + XHTTP + REALITY` | 全场景通用，默认多路复用 |
| 3 | `Trojan + XHTTP + REALITY` | VLESS 替换为 Trojan |
| 4 | 双协议复合 | Vision 回落 XHTTP，共用 443 |
| 5 | SNI 分流复合 | Nginx SNI 分流，REALITY 直连与 CDN 共存 |

SNI 配置额外支持：

- 由 Nginx 实现 SNI 分流，适合过 CDN、上下行分离、多网站共存
- 分享链接支持上下行分离（上行 `xhttp+TLS+CDN` / 下行 `xhttp+Reality`，反之亦可）
- 自定义域名与反代应用管理，每个站点拥有独立证书、站点配置、stream 映射与 UDS

## 分流规则

- 屏蔽 bittorrent 流量（可选）
- 屏蔽回国 IP 流量（可选）
- 屏蔽广告域名（可选）
- 自定义屏蔽分流 / WARP 分流
- Cloudflare WARP Proxy 开关（Docker 部署）
- geodata 自动更新开关

## BBR 加速

首次快速安装（`--vision` / `--xhttp` / `--fallback`）会自动开启 TCP BBR
（拥塞控制 `bbr` + 队列 `fq`）。配置写入 `/etc/sysctl.d/99-xrayscript-bbr.conf`，重启后仍然生效。

- 菜单入口：`管理配置` → `开/关 BBR 加速`
- 命令行：`bash /usr/local/xrayscript/core/handler.sh --bbr toggle|enable|disable|status`
- 内核不支持 BBR（部分 OpenVZ / LXC 容器）时会提示并跳过，不影响其它功能
- 主动关闭后再次快速安装不会强制开启

## 参数默认值与自定义

| 参数 | 默认 | 自定义 |
| --- | --- | --- |
| 端口 | 默认 443 | 支持 1-65535 |
| UUID | 随机生成 | 标准 UUID，或任意字符串由 Xray 映射 |
| trojan password | 随机生成 | 任意输入 |
| target | 从配置中的域名池随机选取 | 支持 TLSv1.3 与 H2 校验、serverNames 自动获取 |
| shortId | 随机（默认两个，长度 8 与 16） | 输入 `0`-`8` 自动生成对应长度；支持逗号分隔多个值 |
| path | 随机生成 | 加不加 `/` 均可 |

## 快速开始

**一键下载并进入界面：**

```sh
wget --no-check-certificate -O ${HOME}/xrayscript-install.sh https://raw.githubusercontent.com/dakerclaw/xrayscript/main/install.sh && bash ${HOME}/xrayscript-install.sh
```

**分步执行：**

```sh
# 1. 下载
wget --no-check-certificate -O ${HOME}/xrayscript-install.sh https://raw.githubusercontent.com/dakerclaw/xrayscript/main/install.sh

# 2. 进入交互界面
bash ${HOME}/xrayscript-install.sh

# 3. 或直接快速安装
bash ${HOME}/xrayscript-install.sh --vision     # VLESS + Vision + REALITY
bash ${HOME}/xrayscript-install.sh --xhttp      # VLESS + XHTTP + REALITY
bash ${HOME}/xrayscript-install.sh --fallback   # Vision + XHTTP 复合
```

## 界面预览

```sh
--------------- xrayscript ------------------
Version      : v2026.11.01
Description  : xrayscript 管理脚本
------------------ 装载管理 ------------------
1. 完整安装
2. 仅安装/更新
3. 卸载
------------------ 操作管理 ------------------
4. 启动
5. 停止
6. 重启
------------------ 配置管理 ------------------
7. 分享链接与二维码
8. 信息统计
9. 管理配置
------------------------------------------------------
0. 退出
```

## 常见问题

1. 安装成功但无法使用：先确认服务器端口已放行，可用 `https://tcp.ping.pe/ip:port` 检查。
2. 使用 SNI 配置前，请确保 VPS 的 80 与 443 端口开放。
3. 使用 SNI 配置前，请不要开启 CDN 保护，否则无法申请 SSL 证书。
4. 上下行分离原理见 [XHTTP: Beyond REALITY](https://github.com/XTLS/Xray-core/discussions/4113) 与 [xhttp 五合一配置](https://github.com/XTLS/Xray-core/discussions/4118)。
5. 签证书时报 `Could not get nonce, let's try again`：查看 [ZeroSSL 状态页](https://status.zerossl.com/)，通常是其 Free ACME Service 处于中断状态。

## 项目结构

```text
.
├── install.sh              # 安装引导脚本（下载项目、装依赖、启动主菜单）
├── config.json             # 脚本自身配置（版本、语言、已生成参数）
├── core/
│   ├── common.sh           # 公共库：OS 检测、i18n 缓存、日志、JSON 工具
│   ├── main.sh             # 主流程调度
│   ├── menu.sh             # 菜单渲染
│   ├── handler.sh          # 核心操作（安装/配置/分流/站点/证书）
│   ├── read.sh             # 交互输入
│   ├── check.sh            # 输入校验与连通性检查
│   ├── generate.sh         # UUID / 密码 / shortId / path 生成
│   └── share.sh            # 分享链接与二维码
├── service/
│   ├── nginx.sh            # Nginx 源码编译、安装、平滑升级
│   ├── ssl.sh              # acme.sh 证书签发与续期
│   └── docker.sh           # Docker / WARP / Cloudreve 容器管理
├── tool/
│   ├── geodata.sh          # geoip / geosite 更新
│   ├── bbr.sh              # TCP BBR 加速开关
│   └── traffic.sh          # 流量统计
├── i18n/                   # 中英文案 (zh.json / en.json)
└── config/                 # Xray 与 Nginx 配置模板
```

## 安装位置

| 组件 | 路径 |
| --- | --- |
| 脚本本体 | `/usr/local/xrayscript` |
| 脚本配置 | `$HOME/.xrayscript/config.json` |
| Nginx | `/usr/local/nginx` |
| Cloudreve | `$HOME/.xrayscript/docker/cloudreve` |
| Cloudflare-warp | `$HOME/.xrayscript/docker/warp` |
| WARP 容器 | `xrayscript-warp` |
| Xray | 见 [Xray-install](https://github.com/XTLS/Xray-install) |

## 依赖

使用 SNI 配置时可能自动安装下列软件包。

| 用途 | Debian 系 | Red Hat 系 |
| --- | --- | --- |
| IP 获取 / 路由 | `iproute2` | `iproute` |
| DNS 解析 | `dnsutils` | `bind-utils` |
| 下载 / 证书 | `wget` `curl` `ca-certificates` | `wget` `curl` `ca-certificates` |
| 进程管理 | `procps` | `procps-ng` |
| 定时任务 | `cron` | `crontabs` |
| 防火墙（二选一） | `ufw` | `firewalld` |
| **编译基础** | `gcc` `g++` `make` `tar` `gzip` `git` | `gcc` `gcc-c++` `make` `tar` `gzip` `git` |
| **acme.sh** | `openssl` | `openssl` |
| **编译 OpenSSL** | `libperl-dev` | `perl-devel` `perl-IPC-Cmd` `perl-Getopt-Long` `perl-Data-Dumper` `perl-FindBin` |
| **编译 Brotli** | `libbrotli-dev` | `brotli-devel` |
| **编译 Nginx** | `libpcre2-dev` `zlib1g-dev` `libxml2-dev` `libxslt1-dev` `libgd-dev` `libgeoip-dev` `libgoogle-perftools-dev` | `pcre2-devel` `zlib-devel` `libxml2-devel` `libxslt-devel` `gd-devel` `geoip-devel` `gperftools-devel` `perl-ExtUtils-Embed` |

## 关于安装时长

SNI 配置的 Nginx 采用源码编译安装，首次安装耗时较长（单核 1G 约 15-20 分钟），适合装一次长期使用。

编译相比二进制安装的优势：启动更快（`-O3` 优化）、版本更新；代价是编译耗时长。

更换为非 SNI 配置后 Nginx 会停止服务但保留在本机，再次启用 SNI 时无需重新安装。

## 免责声明

本项目仅供学习与技术交流使用。请在遵守所在国家或地区法律法规的前提下使用，使用者需自行承担一切使用责任。

[XHTTP]: https://github.com/XTLS/Xray-core/discussions/4113
