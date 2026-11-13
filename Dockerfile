# syntax=docker/dockerfile:1.7

# ============================================================
# ip-derper — 纯 IP 的 Tailscale DERP 中继
#
# 设计取舍见 README.md「安全模型」一节，这里只写编译相关：
#   * 交叉编译（--platform=$BUILDPLATFORM），不依赖 QEMU，arm64 构建同样快
#   * 运行镜像非 root（UID 10001），因此容器内监听 8443，宿主侧映射 443:8443
#   * 基础镜像不写死 digest 是为了让每日自动构建不因 EOL 中断；
#     需要可复现构建时用 renovate.json 打开 digest pinning
# ============================================================

# 由 .github/workflows/build.yml 每日检测 tailscale/tailscale 最新 release 后自动改写
ARG TAILSCALE_VERSION=v1.104.7

ARG ALPINE_VERSION=3.22
ARG GO_IMAGE=golang:1-alpine

# ------------------------------------------------------------
# 阶段一：编译 derper
# ------------------------------------------------------------
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS builder

ARG TAILSCALE_VERSION
ARG TARGETOS
ARG TARGETARCH

ENV CGO_ENABLED=0 \
    GOFLAGS=-trimpath \
    GOTOOLCHAIN=local

RUN apk add --no-cache git ca-certificates

WORKDIR /src

# GOOS/GOARCH 由 buildx 注入，一次构建同时产出 amd64 与 arm64
RUN GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" \
    go install "tailscale.com/cmd/derper@${TAILSCALE_VERSION}" \
 && test -x /go/bin/derper

# ------------------------------------------------------------
# 阶段二：运行
# ------------------------------------------------------------
FROM alpine:${ALPINE_VERSION}

ARG TAILSCALE_VERSION

LABEL org.opencontainers.image.title="ip-derper" \
      org.opencontainers.image.description="Tailscale DERP relay for bare IPs: self-signed cert + CertName pinning" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${TAILSCALE_VERSION}" \
      org.opencontainers.image.source="https://github.com/keyblues/ip-derper"

# /var/lib/derper 是 derper 存 mesh key 的默认路径（-c 缺省值）。
# 根文件系统是 read_only，所以必须由 compose 挂一个可写卷上去，
# 并且目录在镜像里就要属于 derper，否则非 root 进程写不进去会直接 Fatal。
RUN apk add --no-cache ca-certificates openssl tzdata netcat-openbsd \
 && addgroup -S -g 10001 derper \
 && adduser  -S -u 10001 -G derper -h /app -s /sbin/nologin derper \
 && mkdir -p /app/certs /var/lib/derper \
 && chown -R derper:derper /app /var/lib/derper

COPY --from=builder /go/bin/derper /usr/local/bin/derper
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

USER derper
WORKDIR /app

# 8443：容器内非 root 无法绑定 <1024，宿主侧用 ${DERP_PORT:-443}:8443
EXPOSE 8443
EXPOSE 3478/udp

ENV DERP_HOST="" \
    DERP_CERT_DIR="/app/certs" \
    DERP_ADDR=":8443" \
    DERP_HTTP_PORT="-1" \
    DERP_PUBLIC_PORT="443" \
    DERP_STUN="true" \
    DERP_STUN_PORT="3478" \
    DERP_VERIFY_CLIENTS="false" \
    DERP_REGION_ID="900" \
    DERP_REGION_CODE="cn" \
    DERP_NODE_NAME="derp-1" \
    DERP_CERT_DAYS="3650"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
