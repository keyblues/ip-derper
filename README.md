# ip-derper

纯 IP 的 Tailscale DERP 中继。没有域名、不需要 80 端口、不需要 Let's Encrypt —— 靠自签证书 + `CertName` 指纹让客户端信任。

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/keyblues/ip-derper/main/install.sh | bash
```

不带任何参数。装完直接给你能粘进 ACL 的 `derpMap`。

---

## 快速开始

### 1. 一键安装

在 VPS 上用 root 跑：

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/keyblues/ip-derper/main/install.sh | bash
```

`raw.githubusercontent.com` 在国内 VPS 实测 30 秒无响应，所以默认走 `gh-proxy.com`。备用地址：

```bash
# jsDelivr
curl -fsSL https://cdn.jsdelivr.net/gh/keyblues/ip-derper@main/install.sh | bash

# ghproxy.net
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/keyblues/ip-derper/main/install.sh | bash

# 直连（海外 VPS 最快）
curl -fsSL https://raw.githubusercontent.com/keyblues/ip-derper/main/install.sh | bash
```

脚本会自动完成：探测公网 IPv4 → 生成 `docker-compose.yml` → 拉镜像 → 起容器 → 打印 ACL 片段。

**你需要自己决定的只有两件事**（都有合理默认值，可以不管）：

| 场景 | 需要加的参数 |
|---|---|
| 想用 443（需安全组放行，国内云常因备案策略卡住） | `--port 443`（ACL 里的 `DERPPort` 会跟着变） |
| 同一个 tailnet 里跑第二台 | `--region-id 904`（两台用同一个 ID 会互相顶掉） |

完整参数：

```bash
--host <v>              可选，默认 auto（自动探测公网 IP）
--port <n>              宿主 DERP 端口，默认 33380
--stun-port <n>         宿主 STUN 端口，默认 3478
--region-id <n>         900-998，默认 900
--region-code <s>       RegionCode，默认 cn
--node-name <s>         节点名，默认 derp-1
--no-verify-clients     关闭防白嫖（默认开启，需宿主机装并登录 tailscale）
--image <ref>           镜像地址，默认 ghcr.io/keyblues/ip-derper:latest
--dir <path>            安装目录，默认 /opt/ip-derper
-y, --yes               不交互确认
-h, --help              显示帮助
```

### 2. 手动安装（不用脚本）

```bash
mkdir -p /opt/ip-derper/data/certs && cd /opt/ip-derper
# 容器以 uid 10001 运行，目录必须让它可写，否则签证书失败
chown -R 10001:10001 data/certs

cp .env.example .env      # 默认 DERP_HOST=auto，可以不改
docker compose up -d
docker compose logs --no-log-prefix | sed -n '/BEGIN ACL/,/END ACL/p'
```

### 3. 安全组 / 防火墙

| 方向 | 协议 | 端口 | 用途 |
|---|---|---|---|
| 入 | TCP | `33380`（或 `--port`） | DERP 本体，TLS + WebSocket |
| 入 | UDP | `3478`（或 `--stun-port`） | STUN，客户端发现自己的公网 endpoint |
| 入 | UDP | `41641` | tailscaled 打洞端口，**跟本容器无关但必需** |

`41641` 是最常漏的一条。不放通它，节点之间只能靠中继，直连永远打不上。

### 4. 配 ACL

```bash
docker compose -f /opt/ip-derper/docker-compose.yml logs --no-log-prefix \
  | sed -n '/BEGIN ACL/,/END ACL/p'
```

`install.sh` 装完也会直接打一遍。拿到的是完整的一段：

```json
{
  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "900": {
        "RegionID": 900,
        "RegionCode": "cn",
        "RegionName": "derp-1",
        "Nodes": [
          {
            "Name": "derp-1",
            "RegionID": 900,
            "HostName": "1.2.3.4",
            "DERPPort": 33380,
            "STUNPort": 3478,
            "CertName": "sha256-raw:1e9da7f725d8312654e881d89498c8f982c361a701bd995740632e7bb9383649",
            "IPv4": "1.2.3.4"
          }
        ]
      }
    }
  }
}
```

粘到 <https://login.tailscale.com/admin/acls>。已有 `derpMap` 就只合并新的 region。

### 5. 验证

```bash
tailscale debug force-netmap-update                      # 立即拉新配置
tailscale netcheck                                       # 列表里应出现你的 RegionCode
tailscale debug derp 900                                 # 应 Successfully established a DERP connection
tailscale debug metrics | grep recv_data_bytes_derp      # 应开始增长
```

`recv_data_bytes_derp` 是唯一不会骗人的指标 —— `netcheck` 能出延迟只说明 TLS 握得上，不代表中继真的在传数据。

---

## 为什么不用现成的

| 方案 | 问题 |
|---|---|
| `GT-610/ip-derper` | 用 `InsecureForTests` 让客户端跳过校验。**Tailscale 1.104 起不再尊重该字段**，TLS 阶段直接 `x509: certificate signed by unknown authority`；`build_cert.sh` 每次容器启动都重签，指纹天天变；`DERP_VERIFY_CLIENTS=true` 没说要挂 socket，照着做中继 100% 不可用 |
| `bobvane/VPS-Tailscale-DERP-AutoSetup` | 用对了 `CertName`，但自更新和 compose 都从**未校验**的多源下载（含作者自建代理，版本号高者胜出），镜像加速默认走第三方且无 digest 固定 |

这个仓库的取舍：

- **用对的机制**：`CertName: "sha256-raw:<指纹>"`，Tailscale 官方支持的证书固定方式
- **证书只生成一次**：重启、重建容器都不重签，ACL 配一次管十年
- **零第三方下载源**：compose 直接内嵌在 `install.sh` 里，唯一的网络下载是 `install.sh` 自身
- **镜像可验证**：cosign keyless 签名，装了 cosign 就自动校签
- **非 root**：容器内 UID 10001，`cap_drop: ALL`，`no-new-privileges`，根文件系统只读
- **默认防白嫖**：`DERP_VERIFY_CLIENTS=true`，缺 socket 直接 fail fast 而不是静默失效
- **版本自动跟进**：每周一检测 Tailscale 新 release，自动构建双架构镜像并回写 Dockerfile

---

## 工作原理

### 为什么自签证书能work

`CertName` 是 Tailscale 官方的证书固定机制。源码 `ipn/localapi/debugderp.go`：

```go
if suf, ok := strings.CutPrefix(node.CertName, "sha256-raw:"); ok {
    tlsdial.SetConfigExpectedCertHash(conf, suf)
}
```

指纹是证书 DER 的 SHA-256：

```bash
openssl x509 -in data/certs/1.2.3.4.crt -noout -fingerprint -sha256 \
  | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f'
```

### 为什么不用 `InsecureForTests`

那个字段在 Tailscale 源码里的注释是 *"It should not be set by users"*，是单元测试的后门。新版已经忽略它 —— 写了也不生效，但很多人以为自己配了。

### 指纹什么时候会变

只有一种情况：**`data/certs/` 被删掉**。容器重启、镜像升级、`docker compose down/up` 都不会重签（`entrypoint.sh` 先判断文件存在）。

所以：

- **别随手 `rm -rf data/`**，指纹一变 ACL 就得同步改
- 备份 `data/certs/` 整个目录
- 改 `DERP_CERT_DAYS` 不会触发重签，想换有效期得先删证书 —— 那指纹就会变

---

## 安全模型

| 项目 | 做法 |
|---|---|
| 容器用户 | `derper`（UID/GID 10001），非 root |
| 权限 | `cap_drop: ALL`、`no-new-privileges:true` |
| 文件系统 | `read_only: true`；仅 `data/certs` 与 `derper-state` 卷可写 |
| 容器内端口 | 8443（非 root 绑不了 1024 以下），宿主侧 `33380:8443` |
| 镜像来源 | 只有 `ghcr.io`，无第三方加速源 |
| 镜像验证 | cosign keyless 签名；装了 cosign 的机器上 `install.sh` 自动校验 |
| 脚本自我更新 | **没有**。要升级请重新下载 `install.sh` |
| 构建期外联 | Docker Hub（`golang`/`alpine` 基础镜像）、Alpine CDN（`apk` 包）、`goproxy.cn`（Go 模块，可用 `--build-arg GOPROXY_URL` 覆盖）、`github.com`（tailscale 源码） |

DERP 本身是 WireGuard 的中继，**只能看到元数据**（对端公钥、流量大小、时间戳），看不到明文 —— WireGuard 端到端加密，中继没有密钥。

### ⚠️ verify-clients 是 fail-closed 的

这是最容易踩的坑：**derper 拿不到 tailscaled 时，不是放行，而是拒绝所有客户端。**

源码 `derp/derpserver/derpserver.go`：

```go
if s.verifyClientsLocalTailscaled {
    _, err := s.localClient.WhoIsNodeKey(ctx, clientKey)
    if err == local.ErrPeerNotFound {
        return fmt.Errorf("peer %v not authorized", clientKey)
    }
    if err != nil {
        return fmt.Errorf("failed to query local tailscaled status for %v: %w", clientKey, err)
    }
}
```

任何错误都会让 `accept()` 失败、连接被关。所以「开了 `verify-clients` 却没挂 socket」的结果是：容器 `Up`、日志不报错、中继彻底不可用。

而且 `--verify-clients` 读的是**容器内**的 `/var/run/tailscale/tailscaled.sock`。容器的 mount namespace 与宿主机隔离，不 bind mount 进去，那个文件在容器里根本不存在。

本项目的两道保险：

1. compose 默认挂 `/var/run/tailscale:ro`（挂**目录**而不是单个 socket 文件 —— 宿主机没装 tailscale 时，挂文件会让 Docker 在那里建一个同名空目录，反而把 tailscale 弄坏）
2. `entrypoint.sh` 启动前检查 socket，缺了直接退出并给出修法：

```
[ip-derper] FATAL: DERP_VERIFY_CLIENTS=true，但找不到 tailscaled socket: /var/run/tailscale/tailscaled.sock
```

前提是宿主机装了 tailscale 并登录同一个 tailnet：

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

确实要做对公网开放的公用中继，才显式关掉：

```bash
curl -fsSL .../install.sh | bash -s -- --no-verify-clients
```

---

## 环境变量

### `.env` / `install.sh` 用

| 变量 | 默认 | 说明 |
|---|---|---|
| `DERP_HOST` | `auto` | 公网 IPv4 或域名；`auto` = 启动时自动探测 |
| `DERP_IMAGE` | `ghcr.io/keyblues/ip-derper:latest` | 镜像地址 |
| `DERP_PORT` | `33380` | 宿主 DERP 端口。国内 VPS 的 443 常被备案策略或 nginx 占用 |
| `STUN_PORT` | `3478` | 宿主 STUN 端口 |
| `DERP_REGION_ID` | `900` | 900-998，多台机器必须不同 |
| `DERP_REGION_CODE` | `cn` | `netcheck` 里显示的短码 |
| `DERP_NODE_NAME` | `derp-1` | 节点名 |
| `DERP_VERIFY_CLIENTS` | `true` | 防白嫖，fail-closed |
| `DERP_CERT_DAYS` | `3650` | 证书有效期；改它不会自动重签 |

### 容器内

| 变量 | 默认 | 说明 |
|---|---|---|
| `DERP_ADDR` | `:8443` | 容器内监听地址，一般不用改 |
| `DERP_HTTP_PORT` | `-1` | `-1` = 不监听 HTTP。纯 IP 模式不需要 80 |
| `DERP_PUBLIC_PORT` | `33380` | 写进 ACL 的 `DERPPort` |
| `DERP_STUN_PORT` | `3478` | 写进 ACL 的 `STUNPort` |
| `DERP_TAILSCALED_SOCK` | `/var/run/tailscale/tailscaled.sock` | tailscaled socket 路径 |
| `DERP_CONFIG` | `/var/lib/derper/derper.key` | derper 的 mesh key 路径（必须显式传 `-c`） |
| `DERP_IP_DETECT` | `true` | `false` = 禁用自动探测，必须显式给 `DERP_HOST` |
| `DERP_DRY_RUN` | `false` | `true` = 只打印配置不启动，用于调试 |

---

## 版本策略

镜像 tag 跟 Tailscale 官方版本走：

```
ghcr.io/keyblues/ip-derper:v1.104.7
ghcr.io/keyblues/ip-derper:latest
```

`.github/workflows/build.yml` 每周一 03:17 UTC 跑一次：

1. 查 `tailscale/tailscale` 最新 release
2. 查 ghcr 上有没有这个 tag，有就跳过
3. 没有就按架构拆成两个 job 分别构建、按 digest 推送
4. `docker buildx imagetools create` 合并成多架构 manifest，推 `latest` + 版本号
5. cosign keyless 签名（对合并后的 manifest 签名）
6. 把新版本号 `sed` 回 Dockerfile 并提交（`[skip ci]` 防止自触发）

`push` 触发只认 `Dockerfile` / `entrypoint.sh` 的变更，改 workflow 不会白白重建一次镜像。

手动指定版本：`Actions → build → Run workflow → version 填 v1.104.7`

固定用某个版本：

```bash
# .env
DERP_IMAGE=ghcr.io/keyblues/ip-derper:v1.104.7
```

---

## 故障排查

**容器起不来，日志 `derper: -c <config path> not specified`**

derper 只有在 **root** 时才会自动用 `/var/lib/derper/derper.key`；非 root 必须显式传 `-c`。本项目已默认传，除非你改了 `DERP_CONFIG`。

**`tailscale debug derp 900` 报 `x509: certificate signed by unknown authority`**

ACL 里的 `CertName` 缺了，或跟磁盘上的证书对不上：

```bash
openssl x509 -in /opt/ip-derper/data/certs/<IP>.crt -noout -fingerprint -sha256
tailscale debug derp-map | jq '.Regions."900".Nodes[0].CertName'
```

**`recv_data_bytes_derp` 一直是 0**

中继没通。按顺序查：ACL 指纹 → 安全组端口 → `docker compose logs` → `openssl s_client -connect <IP>:33380 </dev/null`。

**`netcheck` 里有这个 region，但流量不走它**

`netcheck` 只证明 TLS 能握手，不证明被选中。用 `tailscale ping <对端>` 看是不是显示你的节点名。

**容器 `Up` 但秒退/重启**

八成是证书目录权限或 tailscaled socket。`docker compose logs` 里会有 `[ip-derper] FATAL:` 开头的具体原因。

**端口被占用**

改 `.env` 里的 `DERP_PORT`（或 `--port`），ACL 里的 `DERPPort` 要跟着改。`STUN_PORT` 同理。

**改了 `data/certs` 之后全断**

指纹变了。重新取 ACL 片段并更新。

---

## 开发

```bash
# 本地构建（当前架构）
docker build --build-arg TAILSCALE_VERSION=v1.104.7 -t ip-derper:dev .

# 双架构（走交叉编译，不需要 QEMU）
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg TAILSCALE_VERSION=v1.104.7 -t ip-derper:dev .

# 覆盖 Go 模块代理（默认 goproxy.cn）
docker build --build-arg GOPROXY_URL=https://proxy.golang.org,direct \
  --build-arg TAILSCALE_VERSION=v1.104.7 -t ip-derper:dev .

# 干跑：只输出 ACL 片段，不起服务
docker run --rm -e DERP_HOST=1.2.3.4 -e DERP_DRY_RUN=true -e DERP_VERIFY_CLIENTS=false ip-derper:dev

# 测试
bats -r tests/
shellcheck -x -S warning install.sh entrypoint.sh
```

---

## 许可

MIT。构建期拉取的 Tailscale 代码遵循其各自的 BSD-3-Clause 许可。
