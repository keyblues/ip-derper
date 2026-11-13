#!/usr/bin/env bats
# entrypoint.sh 的行为测试：只跑 DERP_DRY_RUN 分支，不启动 derper

setup() {
  TMP="$(mktemp -d)"
  export DERP_CERT_DIR="${TMP}/certs"
  export DERP_DRY_RUN=true
  unset DERP_HOST DERP_REGION_ID DERP_NODE_NAME
}

teardown() {
  rm -rf "${TMP}"
}

run_entry() {
  local -a envs=(
    "DERP_CERT_DIR=${DERP_CERT_DIR}"
    "DERP_DRY_RUN=true"
  )
  [ -n "${DERP_HOST:-}" ]      && envs+=("DERP_HOST=${DERP_HOST}")
  [ -n "${DERP_REGION_ID:-}" ] && envs+=("DERP_REGION_ID=${DERP_REGION_ID}")
  [ -n "${DERP_NODE_NAME:-}" ] && envs+=("DERP_NODE_NAME=${DERP_NODE_NAME}")
  run env "${envs[@]}" sh "${BATS_TEST_DIRNAME}/../entrypoint.sh"
  return 0
}

@test "缺少 DERP_HOST 时拒绝启动" {
  run_entry
  [ "$status" -ne 0 ]
  [[ "$output" == *"DERP_HOST 未设置"* ]]
}

@test "DERP_HOST 含 shell 元字符时拒绝启动" {
  export DERP_HOST='1.2.3.4;reboot'
  run_entry
  [ "$status" -ne 0 ]
  [[ "$output" == *"非法字符"* ]]
}

@test "DERP_REGION_ID 越界时拒绝启动" {
  export DERP_HOST='1.2.3.4'
  export DERP_REGION_ID=899
  run_entry
  [ "$status" -ne 0 ]
  [[ "$output" == *"900-998"* ]]
}

@test "合法 IPv4 会生成证书并输出带 CertName 的 ACL" {
  export DERP_HOST='1.2.3.4'
  run_entry
  [ "$status" -eq 0 ]
  [ -f "${DERP_CERT_DIR}/1.2.3.4.crt" ]
  [ -f "${DERP_CERT_DIR}/1.2.3.4.key" ]
  [[ "$output" == *'"CertName": "sha256-raw:'* ]]
  [[ "$output" == *'"HostName": "1.2.3.4"'* ]]
  [[ "$output" == *'"IPv4": "1.2.3.4"'* ]]
  [[ "$output" == *'"STUNPort": 3478'* ]]
}

@test "证书 SAN 含 IP 地址" {
  export DERP_HOST='1.2.3.4'
  run_entry
  run openssl x509 -in "${DERP_CERT_DIR}/1.2.3.4.crt" -noout -ext subjectAltName
  [ "$status" -eq 0 ]
  [[ "$output" == *"IP Address:1.2.3.4"* ]]
}

@test "重复运行复用同一张证书（指纹不变）" {
  export DERP_HOST='1.2.3.4'
  run_entry
  fp1="$(openssl x509 -in "${DERP_CERT_DIR}/1.2.3.4.crt" -noout -fingerprint -sha256)"
  run_entry
  fp2="$(openssl x509 -in "${DERP_CERT_DIR}/1.2.3.4.crt" -noout -fingerprint -sha256)"
  [ "$fp1" = "$fp2" ]
  [[ "$output" == *"复用已有证书"* ]]
}

@test "域名模式使用 DNS SAN 且不写 IPv4 字段" {
  export DERP_HOST='derp.example.com'
  run_entry
  [ "$status" -eq 0 ]
  [[ "$output" == *'"HostName": "derp.example.com"'* ]]
  [[ "$output" != *'"IPv4"'* ]]
  run openssl x509 -in "${DERP_CERT_DIR}/derp.example.com.crt" -noout -ext subjectAltName
  [[ "$output" == *"DNS:derp.example.com"* ]]
}
