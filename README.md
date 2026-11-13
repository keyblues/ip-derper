# ip-derper

纯 IP 的 Tailscale DERP 中继。没有域名、不需要 80 端口、不需要 Let's Encrypt，靠自签证书 + `CertName` 指纹让客户端信任。

```
docker compose up -d
docker compose logs | sed -n '/BEGIN ACL/,/END ACL/p'   # 复制进 ACL
```

---

## 为什么不用现成的

社区里两个常见方案，各自有一个会把人坑住的问题：

| 方案 | 问题 |
|---|---|
| `GT-610/ip-derper` | 自签证书 + `InsecureForTests`。**Tailscale 1.104 起不再尊重这个字段**，TLS 阶段直接 `x509: certificate signed by unknown authority`；而且 `build_cert.sh` 每次容器重启都重签，证书指纹天天变 |
| `bobvane/VPS-Tailscale-DERP-AutoSetup` | 用对了 `CertName` 机制，但自更新和 compose 都从**未校验**的多源下载（含作者自建代理，版本高者胜出），镜像加速默认走第三方且无 digest 固定 |

这个仓库的取舍：

- **对的自签方案**：`CertName: "sha256-raw:<指纹>"`，官方支持的证书固定机制
- **证书只生成一次**：重启不换指纹，ACL 配一次管十年
- **零第三方下载源**：只用 `raw.githubusercontent.com` 和 `ghcr.io`
- **镜像可验证**：cosign keyless 签名，安装脚本能校签
- **非 root 运行**：容器内 UID 10001，`cap_drop: ALL`，`read_only` 根文件系统
- **版本自动跟进**：每周检测 Tailscale 新 release，自动构建双架构镜像并回写 Dockerfile

---

## 快速开始

### 一键安装（推荐）

在 VPS 上用 root 跑一条命令，把 IP 换成你自己的：

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/keyblues/ip-derper/main/install.sh \
  | bash -s -- --host 1.2.3.4
```

国内 VPS **直连 `raw.githubusercontent.com` 会超时**（实测 30s 无响应），所以上面默认走 `gh-proxy.com` 加速。备用地址：

```bash
# jsDelivr（CDN，国内通常很快）
curl -fsSL https://cdn.jsdelivr.net/gh/keyblues/ip-derper@main/install.sh \
  | bash -s -- --host 1.2.3.4

# ghproxy.net
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/keyblues/ip-derper/main/install.sh \
  | bash -s -- --host 1.2.3.4

# 直连（海外 VPS 用这个最快）
curl -fsSL https://raw.githubusercontent.com/keyblues/ip-derper/main/install.sh \
  | bash -s -- --host 1.2.3.4
```

装完会把可直接粘贴的 ACL 片段打出来。常用参数：

```bash
--host 1.2.3.4          必填，公网 IP
--port 443              宿主 DERP 端口
--stun-port 3478        宿主 STUN 端口
--region-id 900         900-998
--node-name derp-1
--verify-clients        只允许本 tailnet 使用（需宿主机已装并登录 tailscale）
--dir /opt/ip-derper    安装目录
-y                      不交互
```

### 手动安装

```bash
mkdir -p /opt/ip-derper/data/certs && cd /opt/ip-derper
# 关键：容器以 uid 10001 运行，目录必须让它可写，否则签证书失败
chown -R 10001:10001 data/certs

cp .env.example .env
vi .env        # 至少把 DERP_HOST 改成你的公网 IP

docker compose up -d
```

### 2. 安全组 / 防火墙

| 方向 | 协议 | 端口 | 用途 |
|---|---|---|---|
| 入 | TCP | `443`（或你设的 `DERP_PORT`） | DERP 本体，TLS + WebSocket |
| 入 | UDP | `3478`（或你设的 `STUN_PORT`） | STUN，供客户端发现自己的公网 endpoint |
| 入 | UDP | `41641` | tailscaled 打洞端口，**跟本容器无关但必需** |

`41641` 是最常漏的一条。不放通它，节点之间就只能靠中继，直连永远打不上。

### 3. 配置 ACL

```bash
docker compose logs --no-log-prefix | sed -n '/BEGIN ACL/,/END ACL/p'
```

拿到类似这样一段：

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
            "DERPPort": 443,
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

粘贴到 <https://login.tailscale.com/admin/acls>。已经有 `derpMap` 就只合并新的 region。

### 4. 验证

```bash
tailscale debug force-netmap-update      # 立即拉新配置
tailscale netcheck                       # 列表里应出现你的 RegionCode
tailscale debug derp 900                 # 应 Successfully established a DERP connection
tailscale debug metrics | grep recv_data_bytes_derp   # 应开始增长（唯一不会骗人的指标）
```

---

## 工作原理

### 为什么自签证书能work

DERP 客户端连服务器时要过 TLS 验证。自签证书没有公共 CA 背书，默认必然失败。

Tailscale 提供了一个官方机制：在 DERP 节点的 `CertName` 字段里写证书指纹，客户端就按指纹固定，跳过 PKI 链验证。

源码见 `ipn/localapi/debugderp.go`：

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

那个字段在 Tailscale 源码里的注释是 *"It should not be set by users"*，是给单元测试留的后门。新版已经忽略它，写了也没用。

### 指纹什么时候会变

只有一种情况：**`data/certs/` 被删掉**。容器重启、镜像升级、`docker compose down` 都不会重签（`entrypoint.sh` 里先判断文件存在）。

所以：

- 证书文件备份一下（`data/certs/` 整个目录）
- 别随手 `rm -rf data/`
- `DERP_CERT_DAYS` 改了不会触发重签 —— 想换有效期得先删证书，那指纹就会变

---

## 安全模型

| 项目 | 做法 |
|---|---|
| 容器用户 | `derper`（UID/GID 10001），非 root |
| 权限 | `cap_drop: ALL` + `no-new-privileges` |
| 根文件系统 | `read_only: true`，仅 `data/certs` 可写 |
| 容器内端口 | 8443（非 root 不能绑 443），宿主侧 `443:8443` |
| 镜像来源 | 只有 `ghcr.io`，无第三方加速源 |
| 镜像验证 | cosign keyless 签名，`install.sh` 自动校签 |
| 脚本自我更新 | **没有**。要升级请 `git pull` 或重新下载 |
| 外部调用 | 构建期只访问 `proxy.golang.org` 和 `github.com` |

关于 DERP 本身：它是 WireGuard 的中继，**只能看到元数据**（对端公钥、流量大小、时间戳），看不到明文 —— WireGuard 端到端加密，中继没有密钥。

`DERP_VERIFY_CLIENTS=false`（默认）时任何人的 tailnet 都能拿你的机器当中继，会烧流量。单人中继建议开成 `true`：

```yaml
# docker-compose.yml 里取消注释
volumes:
  - ./data/certs:/app/certs
  - /var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock
```

```bash
# .env
DERP_VERIFY_CLIENTS=true
```

前提是宿主机装了 tailscale 并登录了同一个 tailnet。

---

## 版本策略

镜像 tag 跟 Tailscale 官方版本走：

```
ghcr.io/keyblues/ip-derper:v1.104.5     # 对应 tailscale v1.104.5
ghcr.io/keyblues/ip-derper:latest
```

`.github/workflows/build.yml` 每周一 03:17 UTC 跑一次：

1. 查 `tailscale/tailscale` 最新 release
2. 查 ghcr 上有没有这个 tag，有就跳过
3. 没有就交叉编译 amd64 + arm64，推 `latest` 和版本号两个 tag
4. cosign keyless 签名（对合并后的多架构 manifest 签名）
5. 把新版本号 `sed` 回 Dockerfile 并提交（`[skip ci]` 防止自触发）

手动指定版本：

```
Actions → build → Run workflow → version 填 v1.104.5
```

固定用某个版本：

```bash
# .env
DERP_IMAGE=ghcr.io/keyblues/ip-derper:v1.104.5
```

---

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `DERP_HOST` | — | **必填**。公网 IPv4 或域名 |
| `DERP_PUBLIC_PORT` | `443` | 客户端实际连接的端口，写进 ACL 的 `DERPPort` |
| `DERP_STUN_PORT` | `3478` | 写进 ACL 的 `STUNPort` |
| `DERP_VERIFY_CLIENTS` | `false` | 只允许本 tailnet 使用 |
| `DERP_REGION_ID` | `900` | 900-998 是 Tailscale 保留给自定义 DERP 的区间 |
| `DERP_REGION_CODE` | `cn` | 出现在 `netcheck` 输出里的短码 |
| `DERP_NODE_NAME` | `derp-1` | 节点名 |
| `DERP_CERT_DAYS` | `3650` | 证书有效期，改它不会自动重签 |
| `DERP_ADDR` | `:8443` | 容器内监听地址，一般不用改 |
| `DERP_HTTP_PORT` | `-1` | `-1` = 不监听 HTTP。纯 IP 模式不需要 80 |
| `DERP_DRY_RUN` | `false` | `true` = 只打印配置不启动，用于调试 |

---

## 故障排查

**`tailscale debug derp 900` 报 `x509: certificate signed by unknown authority`**

ACL 里的 `CertName` 缺了，或者指纹跟磁盘上的证书对不上。核对：

```bash
openssl x509 -in data/certs/<IP>.crt -noout -fingerprint -sha256
tailscale debug derp-map | jq '.Regions."900".Nodes[0].CertName'
```

**`netcheck` 里有这个 region 但流量不走它**

`netcheck` 只证明 TLS 能握手，不证明被选中。用 `tailscale ping <对端>` 看是不是显示你的节点名。

**`recv_data_bytes_derp` 一直是 0**

中继没真正通。按顺序查：ACL 指纹 → 安全组端口 → `docker compose logs` 里 derper 是否起来 → `openssl s_client -connect <IP>:443 </dev/null`。

**端口被占用**

把 `.env` 里的 `DERP_PORT` 改掉（比如 33380），同时 ACL 里的 `DERPPort` 要跟着改。STUN 同理。

**改了 `data/certs` 之后全断**

指纹变了。重新 `docker compose logs | sed -n '/BEGIN ACL/,/END ACL/p'` 并更新 ACL。

---

## 开发

```bash
# 本地构建（当前架构）
docker build --build-arg TAILSCALE_VERSION=v1.104.7 -t ip-derper:dev .

# 双架构（不需要 QEMU，走交叉编译）
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg TAILSCALE_VERSION=v1.104.7 -t ip-derper:dev .

# 国内网络：Go 模块默认已走 goproxy.cn，需要时可显式覆盖
docker build \
  --build-arg GOPROXY_URL=https://goproxy.cn,direct \
  --build-arg TAILSCALE_VERSION=v1.104.7 \
  -t ip-derper:dev .

# 干跑：只输出 ACL 片段，不起服务
docker run --rm -e DERP_HOST=1.2.3.4 -e DERP_DRY_RUN=true ip-derper:dev

# 测试
bats -r tests/
shellcheck -x -S warning install.sh entrypoint.sh
```

---

## 许可

MIT。构建期拉取的 Tailscale 代码遵循其各自的 BSD-3-Clause 许可。
