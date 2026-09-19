#!/usr/bin/env bash
#
# github_vps · 增强版一键脚本
# 基于 https://github.com/1061700625/github_vps 修改
#
# 相比原版做了什么：
#   1. 容器后台运行（up -d），不再占住终端，关掉日志也不影响
#   2. 启动后自动调用 gh CLI 把端口设成 public，省掉手动右键点击
#   3. 自动打印可以点开的完整访问地址
#   4. 新增 status / logs 子命令
#   5. Ubuntu 镜像可选开启"网页桌面"（noVNC），不带 RDP 客户端也能用图形界面
#   6. 启动前做环境自检（docker / compose / KVM / 磁盘），有问题直接说人话
#
# 用法：
#   bash start.sh ubuntu           启动 Ubuntu 22.04 桌面
#   bash start.sh win11            启动 Windows 11 虚拟机（需要 /dev/kvm）
#   bash start.sh stop [ubuntu|win11]
#   bash start.sh status           查看状态 + 访问地址
#   bash start.sh logs [ubuntu|win11]
#   bash start.sh help
#
# 可选环境变量：
#   ROOT_PASSWORD=xxx              改 Ubuntu root 密码（默认 root）
#   WEB_DESKTOP=1                  同时开启网页桌面（noVNC，端口 6080）
#   WINDOWS_PASSWORD=xxx           改 Windows 密码（默认 admin@123）
#   WINDOWS_RAM_SIZE / CPU_CORES / DISK_SIZE ...
#
set -e

MODE="${1:-help}"
TARGET="${2:-all}"

MIN_SIZE_GB=50
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UBUNTU_DIR="$HERE/ubuntu"
WINDOWS_DIR="$HERE/windows"
UBUNTU_COMPOSE="$UBUNTU_DIR/docker-compose.yml"
WINDOWS_COMPOSE="$WINDOWS_DIR/docker-compose.yml"

# 需要对外公开的端口
UBUNTU_PUBLIC_PORTS="4200 6080 8022 3389"
WINDOWS_PUBLIC_PORTS="8006 3389"

# ===== 配置（都可用环境变量覆盖）=====
WINDOWS_USERNAME="${WINDOWS_USERNAME:-MASTER}"
WINDOWS_PASSWORD="${WINDOWS_PASSWORD:-admin@123}"
WINDOWS_VERSION="${WINDOWS_VERSION:-11}"
WINDOWS_RAM_SIZE="${WINDOWS_RAM_SIZE:-4G}"
WINDOWS_CPU_CORES="${WINDOWS_CPU_CORES:-4}"
WINDOWS_DISK_SIZE="${WINDOWS_DISK_SIZE:-64G}"
WINDOWS_DISK2_SIZE="${WINDOWS_DISK2_SIZE:-10G}"

UBUNTU_ROOT_USER="${ROOT_USER:-root}"
UBUNTU_ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
WEB_DESKTOP="${WEB_DESKTOP:-0}"
WEB_DESKTOP_RESOLUTION="${WEB_DESKTOP_RESOLUTION:-1440x900x24}"

# 颜色
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_END=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_END=""
fi

info()  { echo "${C_DIM}$*${C_END}"; }
ok()    { echo "${C_OK}$*${C_END}"; }
warn()  { echo "${C_WARN}$*${C_END}"; }
die()   { echo "${C_ERR}$*${C_END}"; exit 1; }

# ---------------------------------------------------------------- 环境

detect_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    die "❌ 没有 docker compose。请先执行： sudo apt-get update && sudo apt-get install -y docker-compose-plugin"
  fi
}

KVM_OK=0
preflight() {
  command -v docker >/dev/null 2>&1 || die "❌ 找不到 docker 命令，这个环境不支持。"
  detect_compose_cmd
  echo "🔍 环境自检"
  info "   docker     : $(docker --version)"
  info "   compose    : $COMPOSE_CMD"
  if [ -e /dev/kvm ]; then
    KVM_OK=1
    info "   KVM 虚拟化 : ${C_OK}可用${C_END}"
  else
    KVM_OK=0
    info "   KVM 虚拟化 : ${C_WARN}不可用（Windows 模式跑不起来，Ubuntu 模式不受影响）${C_END}"
  fi
  info "   剩余空间   : $(df -h "$HERE" | awk 'NR==2{print $4}')  ($HERE)"
  echo
}

backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    mv "$f" "${f}.bak.$(date +%s)"
  fi
}

# 找一个够大的数据盘（优先 /tmp，其次任意 >=50G 的挂载点）
detect_large_storage() {
  local tmp_dev tmp_kb tmp_gb candidates top
  tmp_dev=""
  tmp_gb=0
  if mountpoint -q /tmp 2>/dev/null; then
    tmp_dev="$(findmnt -n -o SOURCE -T /tmp 2>/dev/null || df -P /tmp | awk 'NR==2{print $1}')"
    tmp_kb="$(df -P /tmp | awk 'NR==2{print $2}')"
    tmp_gb=$(( tmp_kb / 1024 / 1024 ))
  fi

  if [ -n "$tmp_dev" ] && [[ "$tmp_dev" == /dev/* ]] && [ "$tmp_gb" -ge "$MIN_SIZE_GB" ]; then
    TARGET_MOUNT="/tmp"
    echo "✅ 数据盘：/tmp（$tmp_dev，共 ${tmp_gb}G）"
    return
  fi

  candidates="$(df -P -x tmpfs -x devtmpfs -x overlay -x proc -x sysfs -x cgroup -x cgroup2 2>/dev/null \
    | awk 'NR>1 {
        if ($1 ~ /^\/dev\/(loop|ram)/) next
        if ($6 == "/" || $6 == "/vscode" || $6 == "/boot" || $6 == "/workspaces") next
        g = int($2/1024/1024)
        if (g >= 50) print g, $1, $6
      }' | sort -rn)"
  top="$(echo "$candidates" | head -1)"

  if [ -n "$top" ]; then
    TARGET_MOUNT="$(echo "$top" | awk '{print $3}')"
    echo "✅ 数据盘：$TARGET_MOUNT（$(echo "$top" | awk '{print $2}')，共 $(echo "$top" | awk '{print $1}')G）"
  else
    TARGET_MOUNT="$HERE"
    warn "⚠️  没找到 >=${MIN_SIZE_GB}G 的独立数据盘，改用 $HERE"
    warn "    Windows 模式大概率装不下，建议只用 Ubuntu 模式"
  fi
}

# ---------------------------------------------------------------- 端口公开

publish_ports() {
  local ports="$1" args="" p i
  for p in $ports; do args="$args ${p}:public"; done

  if ! command -v gh >/dev/null 2>&1; then
    warn "⚠️  没有 gh CLI，请手动在 PORTS 面板右键端口 → Port Visibility → Public"
    return 0
  fi
  if [ -z "${CODESPACE_NAME:-}" ]; then
    info "ℹ️  非 Codespaces 环境，跳过端口公开"
    return 0
  fi

  echo "🌐 正在把端口设为 public：$ports"
  for i in $(seq 1 24); do
    # shellcheck disable=SC2086
    if gh codespace ports visibility $args -c "$CODESPACE_NAME" >/dev/null 2>&1; then
      ok "✅ 端口已公开"
      return 0
    fi
    sleep 5
  done
  warn "⚠️  自动公开失败，请手动：PORTS 面板 → 右键端口 → Port Visibility → Public"
}

url_for() {
  local port="$1"
  if [ -n "${CODESPACE_NAME:-}" ]; then
    echo "https://${CODESPACE_NAME}-${port}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
  else
    echo "http://localhost:${port}"
  fi
}

print_urls() {
  local ports="$1" p
  echo
  ok "🔗 访问地址（端口设为 public 后可直接点开）"
  for p in $ports; do
    printf '   %-6s %s\n' "$p" "$(url_for "$p")"
  done
}

# ---------------------------------------------------------------- Ubuntu

start_ubuntu() {
  echo "🐧 启动 Ubuntu 22.04 桌面"
  echo
  mkdir -p "$UBUNTU_DIR"
  detect_large_storage
  local storage="$TARGET_MOUNT/ubuntu/ubuntu-data"
  mkdir -p "$storage"
  info "📂 数据目录：$storage"

  backup_file "$UBUNTU_DIR/Dockerfile"
  backup_file "$UBUNTU_DIR/entrypoint.sh"
  backup_file "$UBUNTU_COMPOSE"

  cat > "$UBUNTU_DIR/Dockerfile" << 'DOCKERFILE'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      shellinabox openssh-server sudo vim nano curl wget ca-certificates \
      net-tools iproute2 locales tzdata procps dbus-x11 \
      xrdp xfce4 xfce4-terminal \
      xvfb x11vnc novnc websockify && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN mkdir -p /run/sshd /workspace && \
    printf '\nPermitRootLogin yes\nPasswordAuthentication yes\n' >> /etc/ssh/sshd_config && \
    echo "startxfce4" > /root/.xsession && \
    chmod +x /root/.xsession && \
    adduser xrdp ssl-cert

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 3389 4200 6080

CMD ["/entrypoint.sh"]
DOCKERFILE

  cat > "$UBUNTU_DIR/entrypoint.sh" << 'ENTRY'
#!/bin/bash
set -e

: "${ROOT_PASSWORD:=root}"
: "${WEB_DESKTOP:=0}"
: "${WEB_DESKTOP_RESOLUTION:=1440x900x24}"

echo "🔐 设置 root 密码..."
echo "root:${ROOT_PASSWORD}" | chpasswd

echo "🔑 生成 SSH host keys..."
ssh-keygen -A

mkdir -p /var/run/sshd /var/run/xrdp /var/log/xrdp
rm -f /var/run/xrdp/xrdp.pid /var/run/xrdp/xrdp-sesman.pid

echo "🚀 SSH            -> 8022"
/usr/sbin/sshd

echo "🚀 Web 终端        -> 4200"
/usr/bin/shellinaboxd -t -p 4200 -s "/:LOGIN" &

echo "🚀 XRDP 会话服务   -> 3389"
/usr/sbin/xrdp-sesman

if [ "${WEB_DESKTOP}" = "1" ]; then
  echo "🚀 网页桌面 noVNC  -> 6080"
  export DISPLAY=:1
  Xvfb :1 -screen 0 "${WEB_DESKTOP_RESOLUTION}" >/var/log/xvfb.log 2>&1 &
  sleep 2
  startxfce4 >/var/log/xfce4.log 2>&1 &
  sleep 3
  x11vnc -display :1 -forever -shared -passwd "${ROOT_PASSWORD}" \
         -rfbport 5900 -listen 127.0.0.1 >/var/log/x11vnc.log 2>&1 &
  sleep 1
  websockify --web=/usr/share/novnc 6080 127.0.0.1:5900 >/var/log/websockify.log 2>&1 &
fi

echo "✅ Ubuntu 容器已启动"
exec /usr/sbin/xrdp --nodaemon
ENTRY
  chmod +x "$UBUNTU_DIR/entrypoint.sh"

  cat > "$UBUNTU_COMPOSE" << COMPOSE
services:
  ubuntu:
    build: .
    container_name: ubuntu-web
    hostname: vps
    environment:
      ROOT_PASSWORD: "${UBUNTU_ROOT_PASSWORD}"
      WEB_DESKTOP: "${WEB_DESKTOP}"
      WEB_DESKTOP_RESOLUTION: "${WEB_DESKTOP_RESOLUTION}"
    ports:
      - "4200:4200"
      - "6080:6080"
      - "8022:22"
      - "3389:3389"
    volumes:
      - "${storage}:/workspace"
    restart: unless-stopped
COMPOSE

  echo "🚀 构建并启动（首次 2~5 分钟）..."
  echo
  ( cd "$UBUNTU_DIR" && $COMPOSE_CMD up -d --build )

  publish_ports "$UBUNTU_PUBLIC_PORTS"
  print_urls "$UBUNTU_PUBLIC_PORTS"
  echo
  ok "🎉 Ubuntu 已就绪"
  printf '   %-14s %s\n' "网页终端"   "$(url_for 4200)"
  [ "$WEB_DESKTOP" = "1" ] && printf '   %-14s %s （密码 = root 密码）\n' "网页桌面" "$(url_for 6080)"
  printf '   %-14s %s:%s  用户 %s / 密码 %s\n' "SSH" "<地址>" 8022 "$UBUNTU_ROOT_USER" "$UBUNTU_ROOT_PASSWORD"
  printf '   %-14s %s:%s  用户 %s / 密码 %s\n' "RDP" "<地址>" 3389 "$UBUNTU_ROOT_USER" "$UBUNTU_ROOT_PASSWORD"
  echo
  if [ "$WEB_DESKTOP" != "1" ]; then
    warn "💡 想要网页版图形桌面：先 stop，再用 WEB_DESKTOP=1 bash start.sh ubuntu 启动"
  fi
  warn "⚠️  这些端口现在是公网可访问的，密码务必尽快改掉！"
}

# ---------------------------------------------------------------- Windows

start_windows() {
  echo "🪟 启动 Windows ${WINDOWS_VERSION} 虚拟机"
  echo
  if [ "$KVM_OK" != "1" ]; then
    die "❌ 当前环境没有 /dev/kvm，Windows 虚拟机无法运行。请改用：bash start.sh ubuntu"
  fi
  mkdir -p "$WINDOWS_DIR"
  detect_large_storage
  local storage="$TARGET_MOUNT/windows/docker-windows-storage"
  mkdir -p "$storage"
  info "📂 数据目录：$storage"

  local avail
  avail="$(df -P "$TARGET_MOUNT" | awk 'NR==2{print int($4/1024/1024)}')"
  local need=$(( ${WINDOWS_DISK_SIZE%G} + ${WINDOWS_DISK2_SIZE%G} ))
  info "   可用 ${avail}G / 虚拟磁盘配置 ${need}G（qcow2 稀疏格式，实际按写入量占用）"
  if [ "$avail" -lt "$need" ]; then
    warn "⚠️  空间偏小，Windows 内部写入超过 ${avail}G 就会写满磁盘"
  fi

  backup_file "$WINDOWS_COMPOSE"

  cat > "$WINDOWS_COMPOSE" << COMPOSE
services:
  windows:
    image: dockurr/windows
    container_name: windows
    environment:
      VERSION: "${WINDOWS_VERSION}"
      USERNAME: "${WINDOWS_USERNAME}"
      PASSWORD: "${WINDOWS_PASSWORD}"
      RAM_SIZE: "${WINDOWS_RAM_SIZE}"
      CPU_CORES: "${WINDOWS_CPU_CORES}"
      DISK_SIZE: "${WINDOWS_DISK_SIZE}"
      DISK2_SIZE: "${WINDOWS_DISK2_SIZE}"
    devices:
      - /dev/kvm
      - /dev/net/tun
    cap_add:
      - NET_ADMIN
    ports:
      - "8006:8006"
      - "3389:3389/tcp"
      - "3389:3389/udp"
    volumes:
      - "${storage}:/storage"
    stop_grace_period: 2m
COMPOSE

  echo "🚀 拉起容器（首次要下载镜像 + 安装系统，10~30 分钟）..."
  echo
  ( cd "$WINDOWS_DIR" && $COMPOSE_CMD up -d )

  publish_ports "$WINDOWS_PUBLIC_PORTS"
  print_urls "$WINDOWS_PUBLIC_PORTS"
  echo
  ok "🎉 Windows 已开始安装"
  printf '   %-14s %s\n' "网页画面"  "$(url_for 8006)"
  printf '   %-14s %s:%s  用户 %s / 密码 %s\n' "RDP" "<地址>" 3389 "$WINDOWS_USERNAME" "$WINDOWS_PASSWORD"
  echo
  info "   进度查看：bash start.sh logs win11"
  warn "⚠️  安装期间不要 stop，中途断电要重装"
}

# ---------------------------------------------------------------- 停止 / 状态

stop_ubuntu() {
  echo "🛑 停止 Ubuntu 容器..."
  detect_compose_cmd
  if [ -f "$UBUNTU_COMPOSE" ]; then
    ( cd "$UBUNTU_DIR" && $COMPOSE_CMD down ) 2>/dev/null || true
  fi
  docker stop ubuntu-web 2>/dev/null || true
  docker rm ubuntu-web 2>/dev/null || true
  ok "✅ Ubuntu 已停止"
}

stop_windows() {
  echo "🛑 停止 Windows 容器（需要 1~2 分钟安全关机）..."
  detect_compose_cmd
  if [ -f "$WINDOWS_COMPOSE" ]; then
    ( cd "$WINDOWS_DIR" && $COMPOSE_CMD down ) 2>/dev/null || true
  fi
  docker stop windows 2>/dev/null || true
  docker rm windows 2>/dev/null || true
  ok "✅ Windows 已停止"
}

show_status() {
  echo "📊 容器状态"
  echo
  docker ps -a --filter "name=ubuntu-web" --filter "name=windows" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
  echo
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ubuntu-web$'; then
    publish_ports "$UBUNTU_PUBLIC_PORTS"
    print_urls "$UBUNTU_PUBLIC_PORTS"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^windows$'; then
    publish_ports "$WINDOWS_PUBLIC_PORTS"
    print_urls "$WINDOWS_PUBLIC_PORTS"
  else
    info "当前没有运行中的系统。启动： bash start.sh ubuntu  或  bash start.sh win11"
  fi
}

show_logs() {
  case "$TARGET" in
    win|win11|windows) docker logs -f --tail 120 windows ;;
    ubuntu|linux|all)  docker logs -f --tail 120 ubuntu-web ;;
    *) die "❌ 未知目标：$TARGET" ;;
  esac
}

show_usage() {
  cat << 'USAGE'
用法：
  bash start.sh ubuntu                          启动 Ubuntu 22.04 桌面
  bash start.sh win11                           启动 Windows 11 虚拟机
  WEB_DESKTOP=1 bash start.sh ubuntu            同时开启网页图形桌面（noVNC :6080）
  ROOT_PASSWORD='MyPass@2026' bash start.sh ubuntu   指定 root 密码
  bash start.sh stop [ubuntu|win11]             停止
  bash start.sh status                          查看状态与访问地址
  bash start.sh logs [ubuntu|win11]             跟踪日志

环境变量：
  ROOT_PASSWORD=root            Ubuntu root 密码
  WEB_DESKTOP=1                 开启网页桌面（端口 6080）
  WINDOWS_USERNAME=MASTER       Windows 用户名
  WINDOWS_PASSWORD=admin@123    Windows 密码
  WINDOWS_VERSION=11            11 / 11e / 11l / 2025 / xp 等
  WINDOWS_RAM_SIZE=4G
  WINDOWS_CPU_CORES=4
  WINDOWS_DISK_SIZE=64G
  WINDOWS_DISK2_SIZE=10G

端口：
  Ubuntu  4200 网页终端 | 6080 网页桌面 | 8022 SSH | 3389 RDP
  Windows 8006 网页画面 | 3389 RDP
  注意：两套系统都用 3389，切换前必须先 stop 当前系统
USAGE
}

# ---------------------------------------------------------------- 入口

case "$MODE" in
  ubuntu|linux)
    preflight
    start_ubuntu
    ;;
  win|win11|windows)
    preflight
    start_windows
    ;;
  stop)
    case "$TARGET" in
      all)              stop_windows; stop_ubuntu ;;
      win|win11|windows) stop_windows ;;
      ubuntu|linux)     stop_ubuntu ;;
      *) die "❌ 未知停止目标：$TARGET（可用 ubuntu / win11）" ;;
    esac
    ;;
  status|ps)
    show_status
    ;;
  logs|log)
    show_logs
    ;;
  help|-h|--help|"")
    show_usage
    ;;
  *)
    die "❌ 不支持的模式：$MODE
运行 bash start.sh help 查看用法"
    ;;
esac
