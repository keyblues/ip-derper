#!/bin/sh
# ============================================================
# ip-derper 容器入口
#
#   1. 校验 DERP_HOST（白名单，防参数/shell 注入）
#   2. 幂等签发或复用自签证书（默认 10 年，IP SAN）
#   3. 算出证书 SHA-256 指纹，打印可直接粘贴的 ACL derpMap 片段
#   4. exec derper
#
# 设计要点：
#   * 证书只在缺失时生成 —— 重启不换证书，CertName 指纹永远有效
#     （ip-derper 原版每次重启都重签，这是它最大的坑）
#   * 不用 InsecureForTests（Tailscale 1.104+ 已忽略该字段），
#     用官方支持的 CertName: "sha256-raw:<fp>" 固定证书
# ============================================================
set -eu

log() { printf '[ip-derper] %s\n' "$*"; }
die() { printf '[ip-derper] FATAL: %s\n' "$*" >&2; exit 1; }

DERP_HOST="${DERP_HOST:-}"
DERP_CERT_DIR="${DERP_CERT_DIR:-/app/certs}"
DERP_ADDR="${DERP_ADDR:-:8443}"
DERP_HTTP_PORT="${DERP_HTTP_PORT:--1}"
DERP_PUBLIC_PORT="${DERP_PUBLIC_PORT:-33380}"
DERP_STUN="${DERP_STUN:-true}"
DERP_STUN_PORT="${DERP_STUN_PORT:-3478}"
DERP_VERIFY_CLIENTS="${DERP_VERIFY_CLIENTS:-true}"
DERP_TAILSCALED_SOCK="${DERP_TAILSCALED_SOCK:-/var/run/tailscale/tailscaled.sock}"
DERP_REGION_ID="${DERP_REGION_ID:-900}"
DERP_REGION_CODE="${DERP_REGION_CODE:-cn}"
DERP_NODE_NAME="${DERP_NODE_NAME:-derp-1}"
DERP_CERT_DAYS="${DERP_CERT_DAYS:-3650}"
DERP_CONFIG="${DERP_CONFIG:-/var/lib/derper/derper.key}"
DERP_IP_DETECT="${DERP_IP_DETECT:-true}"
DERP_DRY_RUN="${DERP_DRY_RUN:-false}"

# ------------------------------------------------------------
# 1. 解析 DERP_HOST：不填或填 auto 时自动探测公网 IP
# ------------------------------------------------------------
detect_public_ip() {
  # 多个源，任一成功即可。只用 IPv4 专用端点，避免拿到 IPv6 导致 SAN 类型错。
  for url in \
    "https://api.ip.sb/ip" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip" \
    "https://ipinfo.io/ip" ; do
    ip="$(curl -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
    # 必须是合法 IPv4
    echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || continue
    # 排掉私有 / 保留 / CGNAT 段：探到这些说明出口在 NAT 里，拿它签证书没意义
    case "$ip" in
      10.*|127.*|169.254.*|192.168.*) continue ;;
      172.1[6-9].*|172.2[0-9].*|172.3[01].*) continue ;;
      100.6[4-9].*|100.[7-9][0-9].*|100.1[0-2][0-9].*) continue ;;
    esac
    printf '%s' "$ip"
    return 0
  done
  return 1
}

if [ -z "${DERP_HOST}" ] || [ "${DERP_HOST}" = "auto" ]; then
  [ "${DERP_IP_DETECT}" = "true" ] || die "DERP_HOST 未设置，且 DERP_IP_DETECT 已关闭"
  log "DERP_HOST 未指定，自动探测公网 IPv4..."
  DERP_HOST="$(detect_public_ip)" || die "自动探测公网 IP 失败（容器可能没有出网权限）。
        请显式指定：-e DERP_HOST=<你的公网IP>"
  log "探测到公网 IP: ${DERP_HOST}"
fi

# ------------------------------------------------------------
# 1.1 参数校验
# ------------------------------------------------------------

# 白名单：域名 / IPv4 / IPv6 字面量
case "${DERP_HOST}" in
  *[!A-Za-z0-9._:-]*) die "DERP_HOST 含非法字符: ${DERP_HOST}" ;;
  .*|*.|*..*)         die "DERP_HOST 格式非法: ${DERP_HOST}" ;;
esac

case "${DERP_REGION_ID}" in
  ''|*[!0-9]*) die "DERP_REGION_ID 必须是数字（900-998 留给自定义 DERP）" ;;
esac
[ "${DERP_REGION_ID}" -ge 900 ] && [ "${DERP_REGION_ID}" -le 998 ] \
  || die "DERP_REGION_ID 必须在 900-998 之间，当前 ${DERP_REGION_ID}"

case "${DERP_STUN_PORT}" in
  ''|*[!0-9]*) die "DERP_STUN_PORT 必须是数字" ;;
esac
case "${DERP_PUBLIC_PORT}" in
  ''|*[!0-9]*) die "DERP_PUBLIC_PORT 必须是数字" ;;
esac

# verify-clients 是 fail-closed：拿不到 tailscaled 就拒绝【所有】客户端。
# 不提前拦住的话，容器会显示 running 但中继完全不可用，很难排查。
if [ "${DERP_VERIFY_CLIENTS}" = "true" ] && [ ! -S "${DERP_TAILSCALED_SOCK}" ]; then
  die "DERP_VERIFY_CLIENTS=true，但找不到 tailscaled socket: ${DERP_TAILSCALED_SOCK}
        derper 无法查询本地 tailscaled 时会拒绝所有客户端（不是放行），中继等于死的。二选一：
          1) 宿主机装好 tailscale 并登录，再把 /var/run/tailscale 挂进容器
             （挂目录，别挂单个文件——宿主机没装时 Docker 会把它建成空目录）
          2) 不需要防白嫖：-e DERP_VERIFY_CLIENTS=false"
fi
if [ "${DERP_VERIFY_CLIENTS}" = "true" ]; then
  log "verify-clients 已启用，socket: ${DERP_TAILSCALED_SOCK}"
fi

# ------------------------------------------------------------
# 2. 判定 SAN 类型
# ------------------------------------------------------------
if printf '%s' "${DERP_HOST}" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
  SAN="${DERP_HOST}"
  ACL_EXTRA_IP=",
            \"IPv4\": \"${DERP_HOST}\""
elif printf '%s' "${DERP_HOST}" | grep -qE '^[0-9A-Fa-f:]+$'; then
  SAN="${DERP_HOST}"
  ACL_EXTRA_IP=",
            \"IPv6\": \"${DERP_HOST}\""
else
  SAN="DNS:${DERP_HOST}"
  ACL_EXTRA_IP=""
fi
case "${SAN}" in
  DNS:*) ;;
  *) SAN="IP:${SAN}" ;;
esac

# ------------------------------------------------------------
# 3. 幂等证书
# ------------------------------------------------------------
mkdir -p "${DERP_CERT_DIR}" || die "无法创建证书目录: ${DERP_CERT_DIR}"

# 容器以 uid 10001 运行。宿主 bind mount 过来的目录如果是 root:root 700，
# openssl 会静默失败并只留下一句“签发失败”，所以先显式探一次可写性。
if ! touch "${DERP_CERT_DIR}/.write-test" 2>/dev/null; then
  die "证书目录不可写: ${DERP_CERT_DIR}
        容器内当前 uid=$(id -u)。宿主上执行：
          chown -R 10001:10001 <证书目录>
          chmod 750 <证书目录>"
fi
rm -f "${DERP_CERT_DIR}/.write-test"

# derper --certmode=manual 按 hostname 去掉 [^a-zA-Z0-9.-] 后的名字找证书
CERT_BASE="$(printf '%s' "${DERP_HOST}" | tr -d -c 'a-zA-Z0-9.-')"
[ -n "${CERT_BASE}" ] || die "无法从 DERP_HOST 推导证书文件名"

CERT_FILE="${DERP_CERT_DIR}/${CERT_BASE}.crt"
KEY_FILE="${DERP_CERT_DIR}/${CERT_BASE}.key"

if [ -s "${CERT_FILE}" ] && [ -s "${KEY_FILE}" ]; then
  log "复用已有证书: ${CERT_FILE}"
else
  log "签发自签证书（${DERP_CERT_DAYS} 天，SAN=${SAN}）"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -sha256 -days "${DERP_CERT_DAYS}" -nodes \
    -keyout "${KEY_FILE}" -out "${CERT_FILE}" \
    -subj "/CN=${DERP_HOST}" \
    -addext "subjectAltName=${SAN}" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=critical,serverAuth" \
    >/dev/null 2>&1 \
    || die "openssl 签发证书失败"
  chmod 600 "${KEY_FILE}"
  chmod 644 "${CERT_FILE}"
  log "证书已生成"
fi

# ------------------------------------------------------------
# 4. 指纹 + ACL 片段
# ------------------------------------------------------------
FP="$(openssl x509 -in "${CERT_FILE}" -noout -fingerprint -sha256 2>/dev/null \
      | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')"
[ -n "${FP}" ] || die "无法读取证书指纹"
case "${FP}" in
  *[!0-9a-f]*) die "证书指纹格式异常: ${FP}" ;;
esac

log "证书指纹: sha256-raw:${FP}"
log "--- BEGIN ACL derpMap ---"
cat <<EOF
{
  "derpMap": {
    "OmitDefaultRegions": false,
    "Regions": {
      "${DERP_REGION_ID}": {
        "RegionID": ${DERP_REGION_ID},
        "RegionCode": "${DERP_REGION_CODE}",
        "RegionName": "${DERP_NODE_NAME}",
        "Nodes": [
          {
            "Name": "${DERP_NODE_NAME}",
            "RegionID": ${DERP_REGION_ID},
            "HostName": "${DERP_HOST}",
            "DERPPort": ${DERP_PUBLIC_PORT},
            "STUNPort": ${DERP_STUN_PORT},
            "CertName": "sha256-raw:${FP}"${ACL_EXTRA_IP}
          }
        ]
      }
    }
  }
}
EOF
log "--- END ACL derpMap ---"

if [ "${DERP_DRY_RUN}" = "true" ]; then
  log "DERP_DRY_RUN=true，只输出配置，不启动 derper"
  exit 0
fi

# ------------------------------------------------------------
# 5. 启动 derper
# ------------------------------------------------------------
# 必须显式传 -c：derper 1.10x 起，若不传 -c 且 /var/lib/derper/derper.key 不存在，
# 会直接 "derper: -c <config path> not specified" 退出（不是警告，是 fatal）。
# 该路径由 compose 的 derper-state 命名卷挂载，容器内可写。
mkdir -p "$(dirname "${DERP_CONFIG}")" 2>/dev/null || true

set -- -hostname "${DERP_HOST}" \
       -certmode manual \
       -certdir "${DERP_CERT_DIR}" \
       -c "${DERP_CONFIG}" \
       -a "${DERP_ADDR}" \
       -http-port "${DERP_HTTP_PORT}"

if [ "${DERP_STUN}" = "true" ]; then
  set -- "$@" -stun -stun-port "${DERP_STUN_PORT}"
fi

# 防白嫖：verify-clients 是 fail-closed 的 —— 拿不到 tailscaled 就拒绝所有客户端。
# socket 可用性已在第 1 步校验过，这里只负责传参。
if [ "${DERP_VERIFY_CLIENTS}" = "true" ]; then
  set -- "$@" -verify-clients -socket "${DERP_TAILSCALED_SOCK}"
fi

log "启动: derper $*"
exec /usr/local/bin/derper "$@"
