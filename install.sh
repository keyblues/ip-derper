#!/usr/bin/env bash
# ============================================================
# ip-derper 安装脚本
#
#   curl -fsSL https://raw.githubusercontent.com/keyblues/ip-derper/main/install.sh | bash -s -- --host 1.2.3.4
#   或
#   ./install.sh --host 1.2.3.4 --port 443 --verify-clients
#
# 设计原则（相对常见的"一键脚本"）：
#   * 不从任何第三方加速源下载：本脚本只依赖 GitHub raw + ghcr.io
#   * 不自我更新：要升级请 git pull 或重新下载，脚本本身没有远程执行入口
#   * 镜像可校验：装了 cosign 就校签，没装就打印 digest 供你手工比对
#   * 只写自己目录下的文件（.env / data/），不动 /etc
# ============================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/ip-derper}"
DERP_IMAGE="${DERP_IMAGE:-ghcr.io/keyblues/ip-derper:latest}"
DERP_HOST=""
DERP_PORT="443"
STUN_PORT="3478"
DERP_REGION_ID="900"
DERP_REGION_CODE="cn"
DERP_NODE_NAME="derp-1"
DERP_VERIFY_CLIENTS="false"
ASSUME_YES="false"

C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
[ -t 1 ] || { C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""; }
say()  { printf '%s[*]%s %s\n' "${C_G}" "${C_0}" "$*"; }
warn() { printf '%s[!]%s %s\n' "${C_Y}" "${C_0}" "$*"; }
die()  { printf '%s[x]%s %s\n' "${C_R}" "${C_0}" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: install.sh --host <公网IP或域名> [选项]

  --host <v>              必填。公网 IPv4，或已解析到本机的域名
  --port <n>              宿主 DERP 端口，默认 443
  --stun-port <n>         宿主 STUN 端口，默认 3478
  --region-id <n>         900-998，默认 900
  --region-code <s>       RegionCode，默认 cn
  --node-name <s>         节点名，默认 derp-1
  --verify-clients        只允许本 tailnet 使用（需宿主机装 tailscale）
  --image <ref>           镜像地址，默认 ghcr.io/keyblues/ip-derper:latest
  --dir <path>            安装目录，默认 /opt/ip-derper
  -y, --yes               不交互确认
  -h, --help              显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host)           DERP_HOST="${2:-}"; shift 2 ;;
    --port)           DERP_PORT="${2:-}"; shift 2 ;;
    --stun-port)      STUN_PORT="${2:-}"; shift 2 ;;
    --region-id)      DERP_REGION_ID="${2:-}"; shift 2 ;;
    --region-code)    DERP_REGION_CODE="${2:-}"; shift 2 ;;
    --node-name)      DERP_NODE_NAME="${2:-}"; shift 2 ;;
    --verify-clients) DERP_VERIFY_CLIENTS="true"; shift ;;
    --image)          DERP_IMAGE="${2:-}"; shift 2 ;;
    --dir)            INSTALL_DIR="${2:-}"; shift 2 ;;
    -y|--yes)         ASSUME_YES="true"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "未知参数: $1（-h 查看帮助）" ;;
  esac
done

# ---------------- 前置检查 ----------------
[ "$(id -u)" = "0" ] || die "请用 root 运行（需要写 ${INSTALL_DIR} 和映射 443）"

if [ -z "${DERP_HOST}" ]; then
  [ -t 0 ] || die "非交互环境必须提供 --host"
  printf '请输入本机公网 IP: '
  read -r DERP_HOST
fi
[ -n "${DERP_HOST}" ] || die "DERP_HOST 不能为空"
case "${DERP_HOST}" in
  *[!A-Za-z0-9._:-]*) die "DERP_HOST 含非法字符: ${DERP_HOST}" ;;
esac

command -v docker >/dev/null 2>&1 || die "未安装 docker。装好后重试（本脚本不会替你装）"
docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件（docker compose version 失败）"

for p in "${DERP_PORT}" "${STUN_PORT}" "${DERP_REGION_ID}"; do
  case "${p}" in ''|*[!0-9]*) die "端口/RegionID 必须是数字: ${p}" ;; esac
done
[ "${DERP_REGION_ID}" -ge 900 ] && [ "${DERP_REGION_ID}" -le 998 ] \
  || die "region-id 必须在 900-998（Tailscale 保留给自定义 DERP）"

# ---------------- 拉镜像 ----------------
say "拉取镜像: ${DERP_IMAGE}"
docker pull "${DERP_IMAGE}" || die "镜像拉取失败。
        国内拉 ghcr.io 慢时可以：
          1) 给 docker 配 registry mirror，或
          2) 用加速地址拉下来再打 tag：
               docker pull ghcr.nju.edu.cn/keyblues/ip-derper:latest
               docker tag  ghcr.nju.edu.cn/keyblues/ip-derper:latest ${DERP_IMAGE}
          3) 或直接 --image ghcr.nju.edu.cn/keyblues/ip-derper:latest"

if command -v cosign >/dev/null 2>&1; then
  say "检测到 cosign，校验签名..."
  if cosign verify "${DERP_IMAGE}" \
      --certificate-identity-regexp '^https://github\.com/.*/ip-derper/\.github/workflows/' \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null 2>&1; then
    say "签名校验通过"
  else
    warn "签名校验失败！镜像可能被替换。继续前请人工确认。"
    [ "${ASSUME_YES}" = "true" ] || { printf '仍要继续？[y/N] '; read -r a; [ "$a" = "y" ] || exit 1; }
  fi
else
  warn "未安装 cosign，跳过签名校验。当前镜像 digest："
  docker image inspect --format '{{json .RepoDigests}}' "${DERP_IMAGE}" 2>/dev/null || true
fi

# ---------------- 落盘配置 ----------------
mkdir -p "${INSTALL_DIR}/data/certs"
# 容器以 uid/gid 10001 运行，宿主目录必须让它可写，否则 openssl 签证书会失败
chown -R 10001:10001 "${INSTALL_DIR}/data/certs"
chmod 750 "${INSTALL_DIR}/data/certs"

# compose 模板直接内嵌，不走网络下载：
#   1) 少一个供应链环节（下载来的 compose 可以塞 privileged / 挂根目录）
#   2) raw.githubusercontent.com 在国内 VPS 上常年不稳，内嵌才叫一键
if [ ! -f "${INSTALL_DIR}/docker-compose.yml" ]; then
  say "生成 docker-compose.yml"
  cat > "${INSTALL_DIR}/docker-compose.yml" <<'YAML'
services:
  derper:
    image: ${DERP_IMAGE:-ghcr.io/keyblues/ip-derper:latest}
    container_name: ip-derper
    restart: unless-stopped
    environment:
      DERP_HOST: ${DERP_HOST:?必须设置 DERP_HOST}
      DERP_ADDR: ":8443"
      DERP_HTTP_PORT: "-1"
      DERP_PUBLIC_PORT: ${DERP_PORT:-443}
      DERP_STUN: "true"
      DERP_STUN_PORT: ${STUN_PORT:-3478}
      DERP_VERIFY_CLIENTS: ${DERP_VERIFY_CLIENTS:-false}
      DERP_REGION_ID: ${DERP_REGION_ID:-900}
      DERP_REGION_CODE: ${DERP_REGION_CODE:-cn}
      DERP_NODE_NAME: ${DERP_NODE_NAME:-derp-1}
      DERP_CERT_DAYS: ${DERP_CERT_DAYS:-3650}
    ports:
      - "${DERP_PORT:-443}:8443/tcp"
      - "${STUN_PORT:-3478}:3478/udp"
    volumes:
      - ./data/certs:/app/certs
      - derper-state:/var/lib/derper
    read_only: true
    tmpfs:
      - /tmp
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    healthcheck:
      test: ["CMD-SHELL", "nc -z 127.0.0.1 8443 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  derper-state:
YAML
fi

# verify-clients=true 时挂 tailscaled.sock（不挂的话 derper 拿不到 LocalAPI，全拒）
if [ "${DERP_VERIFY_CLIENTS}" = "true" ]; then
  if [ ! -S /var/run/tailscale/tailscaled.sock ]; then
    die "开了 --verify-clients 但宿主机没有 /var/run/tailscale/tailscaled.sock，先装并登录 tailscale"
  fi
  if ! grep -q 'tailscaled.sock' "${INSTALL_DIR}/docker-compose.yml"; then
    sed -i 's|      - ./data/certs:/app/certs|      - ./data/certs:/app/certs\n      - /var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock|' \
      "${INSTALL_DIR}/docker-compose.yml"
    say "已挂载 tailscaled.sock"
  fi
fi

cat > "${INSTALL_DIR}/.env" <<EOF
DERP_IMAGE=${DERP_IMAGE}
DERP_HOST=${DERP_HOST}
DERP_PORT=${DERP_PORT}
STUN_PORT=${STUN_PORT}
DERP_REGION_ID=${DERP_REGION_ID}
DERP_REGION_CODE=${DERP_REGION_CODE}
DERP_NODE_NAME=${DERP_NODE_NAME}
DERP_VERIFY_CLIENTS=${DERP_VERIFY_CLIENTS}
DERP_CERT_DAYS=${DERP_CERT_DAYS:-3650}
EOF
chmod 600 "${INSTALL_DIR}/.env"

# ---------------- 启动 ----------------
cd "${INSTALL_DIR}"
say "启动容器"
docker compose up -d || die "启动失败，看 docker compose logs"

say "等待证书与配置生成..."
ACL=""
for _ in $(seq 1 30); do
  ACL="$(docker compose logs --no-log-prefix 2>/dev/null \
        | sed -n '/BEGIN ACL derpMap/,/END ACL derpMap/p' | sed '1d;$d')"
  [ -n "${ACL}" ] && break
  sleep 1
done
[ -n "${ACL}" ] || die "没等到 ACL 片段，检查 docker compose logs"

printf '\n%s================ 复制下面这段到 Tailscale Access Controls ================%s\n' "${C_B}" "${C_0}"
printf '%s\n' "${ACL}"
printf '%s========================================================================%s\n\n' "${C_B}" "${C_0}"

cat <<EOF
后续：
  1. 打开 https://login.tailscale.com/admin/acls
  2. 把上面的 "derpMap" 合并进现有 ACL（已存在 Regions 就只加新的那个 region）
  3. 客户端执行 tailscale debug force-netmap-update 立即生效
  4. 验证：
       tailscale netcheck                       # 应出现 ${DERP_REGION_CODE}
       tailscale debug derp ${DERP_REGION_ID}   # 应 Successfully established
       tailscale ping <对端>                    # 应出现 via DERP(${DERP_REGION_CODE})

防火墙/安全组需要放通：
  TCP ${DERP_PORT}    (DERP)
  UDP ${STUN_PORT}   (STUN)
  UDP 41641           (tailscaled 打洞，与本容器无关但必需)

管理：
  cd ${INSTALL_DIR} && docker compose logs -f
  cd ${INSTALL_DIR} && docker compose pull && docker compose up -d   # 升级

注意：data/certs 里是自签证书，删掉会重签 → CertName 指纹变化 → ACL 必须同步更新。
EOF
