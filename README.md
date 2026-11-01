中文 | [English](/README.en.md)

# xrayscript 管理脚本 :sparkles:

纯 Shell 编写的 Xray 一键部署与管理脚本，支持 REALITY、XHTTP、SNI 分流、WARP 分流与自定义反代站点。

- **零依赖安装**：一条 `wget` 命令拉起交互式安装向导
- **六种内置配置**：mKCP / Vision / XHTTP / Trojan / Fallback / SNI
- **图形化菜单**：安装、启停、分享链接、分流、证书全部菜单化操作
- **中英双语**：`i18n/` 目录下的 JSON 驱动，可自行扩展

## 配置类型

| # | 配置 | 说明 |
| --- | --- | --- |
| 1 | `VLESS + mKCP` | 牺牲带宽换取低延迟 |
| 2 | `VLESS + Vision + REALITY` | XTLS Vision 解决 TLS in TLS |
| 3 | `VLESS + XHTTP + REALITY` | 全场景通用，默认多路复用 |
| 4 | `Trojan + XHTTP + REALITY` | VLESS 替换为 Trojan |
| 5 | 双协议复合 | Vision 回落 XHTTP，共用 443 |
| 6 | SNI 分流复合 | Nginx SNI 分流，REALITY 直连与 CDN 共存 |

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

## 参数默认值与自定义

| 参数 | 默认 | 自定义 |
| --- | --- | --- |
| 端口 | mKCP 随机，REALITY 为 443 | 支持 1-65535 |
| UUID | 随机生成 | 标准 UUID，或任意字符串由 Xray 映射 |
| kcp seed / trojan password | 随机生成 | 任意输入 |
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

## 开发

```sh
# 语法检查 + i18n 键一致性 + JSON 合法性
bash .github/scripts/check.sh

# shellcheck
shellcheck -S error -e SC1090,SC1091,SC2016 install.sh core/*.sh service/*.sh tool/*.sh
```

CI 配置见 `.github/workflows/checks.yml`，推送与 PR 时自动执行。

### 本地测试

脚本中的路径均可通过环境变量覆盖，便于在非 root 环境测试：

```sh
XRAY_CONFIG_PATH=/tmp/xray.json NGINX_CONFIG_DIR=/tmp/nginx bash core/handler.sh --xray-config
```

## 更新日志

### v2026.11.01

**健壮性**

| 模块 | 修复内容 |
| --- | --- |
| 分流管理 | 修复规则实际未写入的问题（原实现用关联数组语法读取字符串变量） |
| 路由重置 | `.rules` 为 `null` 时不再报错；重置按 `bt` / `cn` / `ad` 开关生成规则 |
| WARP | 关闭 WARP 时同步清理 `warp-ip` / `warp-domain` 规则 |
| Nginx | 修复 `--brotli` 变量大小写不一致导致的永不生效；不再把 `sites-available/` 整目录拷入；`stream.conf` 的 `default` 改为回落 Reality 站点 |
| 证书 | 用 `trap` 保证异常时恢复 `nginx.conf`；参数统一加引号；切换 CA 改为先重签再写配置 |
| 自定义站点 | 回滚期间使用静默 reload，避免回滚被二次错误打断 |
| 输入校验 | 修复空格校验正则无效；`shortId` 非法值不再死循环 |
| 定时任务 | 统一 `crontab -l 2>/dev/null`，无 crontab 时也能正常增删 |
| 依赖安装 | 缺失依赖一次性安装，不再逐个调用包管理器 |
| 配置写入 | 修复 `cfg_set` 在持久化前调用 `load_config`、从文件重读覆盖修改，导致「仅安装/更新」「修改端口」「切换 CA」等写入全部无效的问题 |
| 版本解析 | 获取 Xray 最新版时按 `published_at` 显式倒序（GitHub 默认按 `created_at` 排序，遇连续预发布可能取到较旧版本），并校验返回值格式 |
| 输入校验 | 交互输入增加重试上限（5 次），避免网络不可用时 `while` 循环无法退出 |
| 安装 | 下载 Xray 安装脚本时支持 GitHub 直连与多个镜像回退；curl 缺失时改用 wget；安装失败不再静默退出 |
| UUID 生成 | 未安装 xray 且 `/proc/sys/kernel/random/uuid` 缺失时（容器 / 精简系统），依次回退到 openssl 与 `/dev/urandom` |
| 界面 | 移除启动 banner 与状态栏（Xray 版本 / 配置类型 / WARP 状态），菜单更紧凑；修复 `CUR_FILE` 在脚本被 `source` 时取错文件名、导致菜单文案为空的问题 |

**性能**

- i18n 一次 `jq` 扁平化为关联数组，取词不再启动子进程
- 脚本配置一次 jq 生成快照，热路径取值零进程开销
- 主菜单合并为一次 `menu.sh --scan`
- 配置文件改为原子写入，移除等待

**结构**

- 新增 `core/common.sh` 公共库，消除 10 份重复代码
- 路径解析改为基于 `${BASH_SOURCE[0]}`，兼容 `source` 与 Windows 路径
- `PATH` 改为追加式，不再覆盖用户已有环境

### 历史版本

- **v2026.03.17**：新增 SNI 自定义域名与反代应用管理
- **v2026.03.01**：新增切换 CA 厂商，事务化重签所有域名证书
- **v2025.11.19**：修复 WARP 容器日志无上限导致占满磁盘

## 免责声明

本项目仅供学习与技术交流使用。请在遵守所在国家或地区法律法规的前提下使用，使用者需自行承担一切使用责任。

[XHTTP]: https://github.com/XTLS/Xray-core/discussions/4113
