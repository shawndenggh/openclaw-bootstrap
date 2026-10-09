#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly INSTALLER_URL="https://openclaw.ai/install.sh"

selected_version="latest"
run_onboard=0
temp_dir=""

readonly DOCKER_APT_URI="https://download.docker.com/linux/ubuntu"
readonly DOCKER_GPG_URL="https://download.docker.com/linux/ubuntu/gpg"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
APT_SOURCES_LIST="${APT_SOURCES_LIST:-/etc/apt/sources.list}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
APT_KEYRINGS_DIR="${APT_KEYRINGS_DIR:-/etc/apt/keyrings}"
SYSTEMD_RUN_DIR="${SYSTEMD_RUN_DIR:-/run/systemd/system}"
DOCKER_SOURCE_FILE="${DOCKER_SOURCE_FILE:-$APT_SOURCES_DIR/openclaw-bootstrap-docker.sources}"
DOCKER_KEY_FILE="${DOCKER_KEY_FILE:-$APT_KEYRINGS_DIR/openclaw-bootstrap-docker.asc}"

usage() {
  cat <<'EOF'
用法：
  install.sh [--version VERSION] [--onboard]
  install.sh --help

选项：
  --version VERSION  安装指定 OpenClaw 版本，默认值：latest
  --onboard          安装完成后运行交互式引导：openclaw onboard
  --help             显示帮助

说明：
  - 仅支持 Ubuntu
  - 仅支持 x86_64 与 aarch64 架构
  - 默认会先确保 Docker Engine 与 Docker Compose v2（docker compose）可用，
    即使 openclaw 已安装也会检查，缺失时才补装
  - 已有可用的 docker 与 docker compose：不安装任何 Docker 软件包，不改动服务
  - 已有 Docker 但缺少 Compose v2：仅安装兼容的 Compose 软件包，不重装、不升级、不重启现有引擎
  - 全新安装 Docker：使用 Docker 官方 Ubuntu apt 源；若 systemd 正在运行则启用并启动 docker 服务
  - 发现冲突的发行版/Podman 软件包或损坏的 docker 命令时直接报错退出，
    不会卸载、替换、删除数据，也不会自动修改 docker 用户组、daemon.json 或防火墙
  - 如果系统中已存在 openclaw，则跳过安装且不会升级或覆盖现有配置
  - 显式指定 --onboard 时仍会运行 openclaw onboard，该向导可能修改配置
EOF
}

log() {
  printf '%s\n' "$*"
}

err() {
  printf '错误：%s\n' "$*" >&2
}

die() {
  err "$@"
  exit 1
}

cleanup() {
  if [[ -n "${temp_dir:-}" && -d "${temp_dir:-}" ]]; then
    rm -rf -- "$temp_dir"
  fi
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --version)
        if (($# < 2)) || [[ -z "${2:-}" ]] || [[ "${2:-}" == --* ]]; then
          die "--version 需要提供版本号。"
        fi
        selected_version="$2"
        shift 2
        ;;
      --onboard)
        run_onboard=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        if (($# > 0)); then
          die "不支持的位置参数：$*"
        fi
        break
        ;;
      -*)
        die "未知参数：$1"
        ;;
      *)
        die "不支持的位置参数：$1"
        ;;
    esac
  done
}

require_tty_for_onboard() {
  if (( run_onboard )) && ! ( : </dev/tty ) 2>/dev/null; then
    cat >&2 <<'EOF'
错误：检测到 --onboard，但当前没有可用的交互终端，无法安全运行 `openclaw onboard`。

请改为以下步骤：
1. 先执行安装（不要带 --onboard）。
2. 在可交互终端中运行：openclaw onboard
3. 完成 OpenClaw Gateway 配置后，再运行：openclaw gateway install
EOF
    exit 1
  fi
}

check_platform() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，无法确认系统是否为 Ubuntu。"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "仅支持 Ubuntu，当前系统：${PRETTY_NAME:-未知系统}。"

  case "$(uname -m)" in
    x86_64|aarch64)
      ;;
    *)
      die "仅支持 x86_64 与 aarch64 架构，当前架构：$(uname -m)。"
      ;;
  esac
}

have_ca_certificates() {
  dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -qx 'install ok installed'
}

append_path_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
}

add_common_bin_paths() {
  append_path_dir "$HOME/.npm-global/bin"
  append_path_dir "$HOME/.local/bin"
  append_path_dir "$HOME/.openclaw/bin"
}

install_missing_prerequisites() {
  local -a missing_packages=()

  if ! have_ca_certificates; then
    missing_packages+=("ca-certificates")
  fi
  if ! command -v curl >/dev/null 2>&1; then
    missing_packages+=("curl")
  fi
  if ! command -v git >/dev/null 2>&1; then
    missing_packages+=("git")
  fi

  if ((${#missing_packages[@]} == 0)); then
    return 0
  fi

  log "检测到缺少依赖：${missing_packages[*]}"
  command -v apt-get >/dev/null 2>&1 || die "系统中未找到 apt-get，无法安装依赖。"
  ensure_priv

  log "正在安装缺失依赖..."
  apt_priv update
  apt_priv install -y --no-install-recommends "${missing_packages[@]}"
}

is_root() {
  (( EUID == 0 ))
}

ensure_priv() {
  is_root && return 0
  command -v sudo >/dev/null 2>&1 || die "需要 root 权限但未找到 sudo。请以具备 sudo 权限的用户运行，或先以 root 手动完成所需安装。"
  if ! sudo -n true 2>/dev/null; then
    die "需要 root 权限，但当前无法使用 sudo -n 无人值守提权。请先运行 sudo -v 刷新凭据后重试，或配置免密 sudo。"
  fi
}

run_priv() {
  if is_root; then
    "$@"
  else
    sudo -n "$@"
  fi
}

apt_priv() {
  run_priv env DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

ensure_temp_dir() {
  if [[ -z "${temp_dir:-}" || ! -d "${temp_dir:-}" ]]; then
    temp_dir="$(mktemp -d)"
  fi
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

pkg_has_candidate() {
  local candidate=""
  candidate="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -n 1)"
  [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

docker_compose_ok() {
  docker compose version >/dev/null 2>&1
}

check_existing_docker() {
  local version_output=""
  if ! version_output="$(docker --version 2>&1)"; then
    die "检测到 docker 命令但 docker --version 执行失败，脚本不会替换它。请先修复或移除该命令后重试。"
  fi
  if grep -qi 'podman' <<<"$version_output"; then
    die "检测到 docker 命令是 Podman 兼容层（${version_output}），不是 Docker Engine，脚本不会替换它。请自行处理后重试。"
  fi
}

check_fresh_docker_conflicts() {
  local -a found=()
  local pkg
  for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
    if pkg_installed "$pkg"; then
      found+=("$pkg")
    fi
  done
  if ((${#found[@]} > 0)); then
    err "检测到已安装的冲突或残留的 Docker 相关软件包：${found[*]}"
    err "脚本不会卸载、替换这些软件包，也不会删除任何数据。"
    die "请按 Docker 官方文档自行评估并处理这些软件包（或修复现有 Docker 安装）后再重新运行本脚本。"
  fi
}

has_official_docker_source() {
  local f
  for f in "$APT_SOURCES_LIST" "$APT_SOURCES_DIR"/*.list; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*deb[[:space:]].*https?://download\.docker\.com/linux/ubuntu([/[:space:]]|$)' "$f"; then
      return 0
    fi
  done
  for f in "$APT_SOURCES_DIR"/*.sources; do
    [[ -f "$f" ]] || continue
    if awk 'BEGIN { RS=""; FS="\n" }
      { uri=0; enabled=1; binary=0
        for (i=1; i<=NF; i++) {
          if ($i ~ /^URIs:[[:space:]].*https?:\/\/download\.docker\.com\/linux\/ubuntu([/[:space:]]|$)/) uri=1
          if (tolower($i) ~ /^enabled:[[:space:]]*no([[:space:]]|$)/) enabled=0
          if ($i ~ /^Types:[[:space:]]*deb([[:space:]]|$)/) binary=1
        }
        if (uri && enabled && binary) found=1
      }
      END { exit !found }' "$f"; then
      return 0
    fi
  done
  return 1
}

setup_docker_apt_source() {
  if has_official_docker_source; then
    log "已检测到 Docker 官方 apt 源，直接复用，不会重复添加或覆盖。"
    return 0
  fi

  if [[ -e "$DOCKER_SOURCE_FILE" || -e "$DOCKER_KEY_FILE" ]]; then
    die "已存在 $DOCKER_SOURCE_FILE 或 $DOCKER_KEY_FILE，但内容不是 Docker 官方 Ubuntu 源，脚本不会覆盖。请检查后手动处理。"
  fi

  ensure_priv
  install_missing_prerequisites
  ensure_temp_dir

  local codename="" arch=""
  [[ -r "$OS_RELEASE_FILE" ]] || die "无法读取 $OS_RELEASE_FILE。"
  codename="$(. "$OS_RELEASE_FILE" && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
  [[ -n "$codename" ]] || die "无法从 $OS_RELEASE_FILE 获取 Ubuntu 代号。"
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64|arm64) ;;
    *) die "不支持的 dpkg 架构：$arch。" ;;
  esac

  local key_tmp="$temp_dir/docker.asc" src_tmp="$temp_dir/docker.sources"
  log "正在下载 Docker 官方 GPG 密钥..."
  curl \
    --fail \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --retry-delay 2 \
    --retry-connrefused \
    --output "$key_tmp" \
    "$DOCKER_GPG_URL"
  grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$key_tmp" || die "下载的 Docker GPG 密钥格式不正确。"

  printf '%s\n' \
    "Types: deb" \
    "URIs: $DOCKER_APT_URI" \
    "Suites: $codename" \
    "Components: stable" \
    "Architectures: $arch" \
    "Signed-By: $DOCKER_KEY_FILE" >"$src_tmp"

  log "正在添加 Docker 官方 apt 源..."
  run_priv install -d -m 0755 "$APT_KEYRINGS_DIR"
  run_priv install -m 0644 "$key_tmp" "$DOCKER_KEY_FILE"
  run_priv install -m 0644 "$src_tmp" "$DOCKER_SOURCE_FILE"
  apt_priv update
}

systemd_running() {
  [[ -d "$SYSTEMD_RUN_DIR" ]] && command -v systemctl >/dev/null 2>&1
}

readonly CORE_ENGINE_PATTERN='^(docker-ce|docker-ce-cli|docker-ce-rootless-extras|docker\.io|docker-engine|docker-doc|containerd|containerd\.io|runc|podman|podman-docker|moby-.*)$'

simulate_compose_install() {
  local pkg="$1" sim_out="" kind name rest
  if ! sim_out="$(LC_ALL=C apt-get -s --no-remove --no-upgrade --no-install-recommends install "$pkg" 2>&1)"; then
    die "模拟安装 $pkg 失败，已放弃以避免影响现有 Docker：$sim_out"
  fi
  if grep -q '^Remv ' <<<"$sim_out"; then
    die "安装 $pkg 会移除已有软件包，已拒绝。"
  fi
  while read -r kind name rest; do
    [[ "$kind" == "Inst" ]] || continue
    name="${name%%:*}"
    if [[ "$name" =~ $CORE_ENGINE_PATTERN ]]; then
      die "安装 $pkg 会安装或升级 Docker/containerd/runc 等引擎核心软件包（$name），已拒绝以避免替换现有引擎。"
    fi
  done <<<"$sim_out"
}

install_compose_only() {
  local pkg=""
  command -v apt-get >/dev/null 2>&1 || die "系统中未找到 apt-get，无法安装 Docker Compose v2。"
  ensure_priv
  log "已有 Docker，但缺少 Compose v2，仅安装 Compose 软件包（不会改动现有引擎）..."
  apt_priv update

  if pkg_has_candidate docker-compose-plugin; then
    pkg="docker-compose-plugin"
  elif pkg_has_candidate docker-compose-v2; then
    pkg="docker-compose-v2"
  else
    setup_docker_apt_source
    pkg_has_candidate docker-compose-plugin || die "官方 Docker 源中仍找不到 docker-compose-plugin。"
    pkg="docker-compose-plugin"
  fi

  simulate_compose_install "$pkg"
  apt_priv install -y --no-remove --no-upgrade --no-install-recommends "$pkg"
  docker_compose_ok || die "安装 $pkg 后 docker compose version 仍不可用。"
  log "Docker Compose v2 已可用：$(docker compose version)"
}

install_fresh_docker() {
  command -v apt-get >/dev/null 2>&1 || die "系统中未找到 apt-get，无法安装 Docker。"
  check_fresh_docker_conflicts
  ensure_priv
  install_missing_prerequisites
  setup_docker_apt_source
  apt_priv update

  log "正在安装 Docker Engine 与 Compose v2..."
  apt_priv install -y --no-remove --no-upgrade --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  if systemd_running; then
    run_priv systemctl enable --now docker
  else
    log "未检测到运行中的 systemd，Docker 服务不会自动启动，请自行启动 docker 服务。"
  fi

  docker --version >/dev/null 2>&1 || die "安装后 docker --version 不可用。"
  docker_compose_ok || die "安装后 docker compose version 不可用。"
  log "Docker 已安装：$(docker --version)"
  log "Docker Compose 已可用：$(docker compose version)"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    check_existing_docker
    if docker_compose_ok; then
      log "已检测到可用的 Docker 与 Docker Compose v2，跳过 Docker 安装。"
      return 0
    fi
    install_compose_only
    return 0
  fi
  install_fresh_docker
}

download_official_installer() {
  ensure_temp_dir
  local installer_path="$temp_dir/openclaw-install.sh"

  log "正在下载官方安装器..."
  curl \
    --fail \
    --show-error \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --retry-delay 2 \
    --retry-connrefused \
    --output "$installer_path" \
    "$INSTALLER_URL"

  log "正在校验安装器语法..."
  bash -n "$installer_path"

  log "正在执行官方安装器..."
  bash "$installer_path" \
    --install-method npm \
    --version "$selected_version" \
    --no-prompt \
    --no-onboard
}

verify_openclaw_available() {
  add_common_bin_paths
  hash -r
  local openclaw_path=""
  openclaw_path="$(command -v openclaw || true)"
  [[ -n "$openclaw_path" ]] || die "安装完成后仍未找到 openclaw。请检查 PATH，常见目录包括 ~/.npm-global/bin、~/.local/bin 和 ~/.openclaw/bin。"

  local installed_version=""
  installed_version="$(openclaw --version)"
  [[ -n "$installed_version" ]] || die "无法确认 openclaw 版本。"

  log "OpenClaw 已可用：$openclaw_path"
  log "OpenClaw 版本：$installed_version"
}

print_next_steps() {
  (( run_onboard )) && return 0
  log "后续步骤："
  log "  1. openclaw onboard"
  log "  2. openclaw gateway install"
}

run_onboarding() {
  (( run_onboard )) || return 0
  log "正在启动交互式引导..."
  openclaw onboard </dev/tty
}

main() {
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  parse_args "$@"
  require_tty_for_onboard
  check_platform
  add_common_bin_paths
  ensure_docker

  if command -v openclaw >/dev/null 2>&1; then
    log "已检测到现有 OpenClaw：$(command -v openclaw)"
    log "跳过安装，不会升级或覆盖现有配置。"
    run_onboarding
    print_next_steps
    return 0
  fi

  install_missing_prerequisites
  download_official_installer
  verify_openclaw_available
  run_onboarding
  print_next_steps
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
