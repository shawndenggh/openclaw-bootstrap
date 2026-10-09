#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly INSTALLER_URL="https://openclaw.ai/install.sh"

selected_version="latest"
run_onboard=0
temp_dir=""

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

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

  if (( EUID == 0 )); then
    log "正在以 root 身份安装缺失依赖..."
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"
    return 0
  fi

  command -v sudo >/dev/null 2>&1 || die "缺少 sudo，无法自动安装依赖。请先以 root 安装：${missing_packages[*]}"
  if ! sudo -n true 2>/dev/null; then
    die "缺少依赖且当前无法使用 sudo -n 无人值守安装。请先手动执行：sudo apt-get update && sudo apt-get install -y --no-install-recommends ${missing_packages[*]}"
  fi

  log "正在通过 sudo -n 安装缺失依赖..."
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_packages[@]}"
}

download_official_installer() {
  temp_dir="$(mktemp -d)"
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
  parse_args "$@"
  require_tty_for_onboard
  check_platform
  add_common_bin_paths

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

main "$@"
