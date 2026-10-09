#!/usr/bin/env bash
# Mock-only regression tests: every mutating/external command is a logging stub.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

pass=0
fail=0

new_env() {
  T="$WORK/$1"
  B="$T/bin"
  S="$T/state"
  mkdir -p "$B" "$S" "$T/sources.d" "$T/keyrings" "$T/run"
  : >"$S/log"; : >"$S/installed"; : >"$S/candidates"
  printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' >"$T/os-release"
  : >"$T/sources.list"

  cat >"$S/docker-template" <<EOF
#!/usr/bin/env bash
echo "docker \$*" >>"$S/log"
[[ -e "$S/docker_broken" ]] && exit 1
if [[ "\$1" == "--version" ]]; then
  [[ -e "$S/podman" ]] && echo "podman version 5" || echo "Docker version 27"
  exit 0
fi
[[ "\$1 \$2" == "compose version" && -e "$S/compose" ]] && { echo "Docker Compose version v2"; exit 0; }
exit 1
EOF
  chmod +x "$S/docker-template"

  # Logging stubs for every command that could mutate or reach the network.
  local cmd
  for cmd in sudo systemctl install curl git openclaw apt-get apt-cache dpkg dpkg-query; do
    cat >"$B/$cmd" <<EOF
#!/usr/bin/env bash
echo "$cmd \$*" >>"$S/log"
case "$cmd" in
  sudo) [[ "\$1" == "-n" ]] && shift; exec "\$@" ;;
  curl) while (("\$#")); do [[ "\$1" == "--output" ]] && echo "-----BEGIN PGP PUBLIC KEY BLOCK-----" >"\$2"; shift; done ;;
  install) [[ "\${@: -1}" == *docker.sources ]] && touch "$S/repo-ready" ;;
  dpkg) echo amd64 ;;
  dpkg-query) grep -qx "\${@: -1}" "$S/installed" && printf 'install ok installed' || exit 1 ;;
  apt-cache) grep -qx "\${@: -1}" "$S/candidates" && echo "  Candidate: 1.0" || echo "  Candidate: (none)" ;;
  apt-get)
    if [[ "\$1" == "-s" ]]; then cat "$S/sim" 2>/dev/null || true
    elif [[ "\$1" == "update" && -e "$S/repo-ready" && -e "$S/after-repo" ]]; then
      cat "$S/after-repo" >"$S/candidates"
    elif [[ " \$* " == *" install "* ]]; then
      [[ " \$* " == *" docker-ce "* ]] && { cp "$S/docker-template" "$B/docker"; touch "$S/compose"; }
      [[ " \$* " == *" docker-compose-"* ]] && touch "$S/compose"
    fi ;;
esac
exit 0
EOF
    chmod +x "$B/$cmd"
  done
  # Only harmless real tools are exposed so a host docker/apt can never be reached.
  local tool
  for tool in bash env true cat grep sed head tr awk mkdir rm mktemp dirname uname touch cp chmod; do
    ln -sf "$(type -P "$tool")" "$B/$tool"
  done
}

put_docker() { cp "$S/docker-template" "$B/docker"; }

# run_case NAME EXPECTED_RC BODY; BODY runs in a fresh bash with the functions sourced.
run_case() {
  local name="$1" want="$2" body="$3" rc=0
  OUT="$(PATH="$B" OS_RELEASE_FILE="$T/os-release" APT_SOURCES_LIST="$T/sources.list" \
    APT_SOURCES_DIR="$T/sources.d" APT_KEYRINGS_DIR="$T/keyrings" SYSTEMD_RUN_DIR="$T/run/systemd" \
    TMPDIR="$T/run" bash -c "source '$SCRIPT'; is_root() { return 1; }; add_common_bin_paths() { :; }; $body" 2>&1)" || rc=$?
  LOG="$(cat "$S/log")"
  if [[ "$rc" != "$want" ]]; then
    echo "FAIL $name: rc=$rc want=$want"; echo "$OUT"; echo "$LOG"; fail=$((fail + 1)); return 1
  fi
}

expect_log() { grep -qE -- "$1" <<<"$LOG" || { echo "FAIL $CASE: missing log /$1/"; echo "$LOG"; fail=$((fail + 1)); return 1; }; }
expect_no_log() { ! grep -qE -- "$1" <<<"$LOG" || { echo "FAIL $CASE: unexpected log /$1/"; echo "$LOG"; fail=$((fail + 1)); return 1; }; }
done_case() { pass=$((pass + 1)); echo "ok   $CASE"; }

CASE="all installed: no changes"
new_env a; put_docker; touch "$S/compose"
if run_case "$CASE" 0 ensure_docker && expect_no_log 'apt-get|sudo|systemctl|install '; then done_case; fi

CASE="fresh install: packages and service"
new_env b; mkdir "$T/run/systemd"
printf 'ca-certificates\n' >"$S/installed"
if run_case "$CASE" 0 ensure_docker \
  && expect_log 'apt-get install -y --no-remove --no-upgrade --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' \
  && expect_log 'systemctl enable --now docker' \
  && expect_log 'install -m 0644 .*openclaw-bootstrap-docker.sources' \
  && expect_log 'download.docker.com/linux/ubuntu/gpg' \
  && expect_no_log 'apt-key|hello-world|usermod|daemon.json|autoremove|purge'; then done_case; fi

CASE="fresh install without systemd: no service start"
new_env c
if run_case "$CASE" 0 ensure_docker && expect_no_log 'systemctl' && grep -q '不会自动启动' <<<"$OUT"; then done_case; fi

CASE="fresh install reuses existing official source"
new_env d
printf 'ca-certificates\n' >"$S/installed"
echo 'deb [signed-by=/x] https://download.docker.com/linux/ubuntu noble stable' >"$T/sources.d/docker.list"
if run_case "$CASE" 0 ensure_docker && expect_no_log 'install -m 0644' && expect_no_log 'curl'; then done_case; fi

CASE="engine present, compose missing: only compose installed"
new_env e; put_docker; echo docker-compose-plugin >"$S/candidates"
echo 'Inst docker-compose-plugin (2.0 Docker)' >"$S/sim"
if run_case "$CASE" 0 ensure_docker \
  && expect_log 'apt-get install -y --no-remove --no-upgrade --no-install-recommends docker-compose-plugin$' \
  && expect_log 'apt-get -s --no-remove --no-upgrade --no-install-recommends install docker-compose-plugin' \
  && expect_no_log 'docker-ce|systemctl|containerd'; then done_case; fi

CASE="compose falls back to docker-compose-v2"
new_env f; put_docker; echo docker-compose-v2 >"$S/candidates"
echo 'Inst docker-compose-v2 (2.0 Ubuntu)' >"$S/sim"
if run_case "$CASE" 0 ensure_docker && expect_log 'no-install-recommends docker-compose-v2$'; then done_case; fi

CASE="compose simulation touching engine is rejected"
new_env g; put_docker; echo docker-compose-v2 >"$S/candidates"
printf 'Inst docker-compose-v2 (2.0)\nInst docker.io:amd64 (27)\n' >"$S/sim"
if run_case "$CASE" 1 ensure_docker && expect_no_log 'apt-get (-y )?install'; then done_case; fi

CASE="compose simulation with removal is rejected"
new_env h; put_docker; echo docker-compose-plugin >"$S/candidates"
printf 'Remv foo (1)\nInst docker-compose-plugin (2.0)\n' >"$S/sim"
if run_case "$CASE" 1 ensure_docker && expect_no_log 'apt-get (-y )?install'; then done_case; fi

CASE="conflicting distro package fails before any mutation"
new_env i; printf 'docker.io\n' >"$S/installed"
if run_case "$CASE" 1 ensure_docker && expect_no_log 'apt-get|install |systemctl|curl' && grep -q 'docker.io' <<<"$OUT"; then done_case; fi

CASE="partial docker-ce install fails before any mutation"
new_env j; printf 'docker-ce-cli\n' >"$S/installed"
if run_case "$CASE" 1 ensure_docker && expect_no_log 'apt-get|install |systemctl|curl'; then done_case; fi

CASE="podman shim fails without replacing"
new_env k; put_docker; touch "$S/podman"
if run_case "$CASE" 1 ensure_docker && expect_no_log 'apt-get|install |systemctl'; then done_case; fi

CASE="broken docker fails without replacing"
new_env l; put_docker; touch "$S/docker_broken"
if run_case "$CASE" 1 ensure_docker && expect_no_log 'apt-get|install |systemctl'; then done_case; fi

CASE="main with existing OpenClaw still ensures Docker"
new_env m; put_docker; echo docker-compose-plugin >"$S/candidates"
echo 'Inst docker-compose-plugin (2.0)' >"$S/sim"
if run_case "$CASE" 0 'check_platform() { :; }; main' \
  && expect_log 'no-install-recommends docker-compose-plugin$' \
  && expect_no_log 'openclaw (onboard|--version)|curl'; then done_case; fi

CASE="compose missing candidates adds official source"
new_env n; put_docker; echo docker-compose-plugin >"$S/after-repo"
printf 'ca-certificates\n' >"$S/installed"
if run_case "$CASE" 0 ensure_docker \
  && expect_log 'install -m 0644 .*openclaw-bootstrap-docker.sources' \
  && expect_log 'no-install-recommends docker-compose-plugin$' \
  && expect_no_log 'systemctl|docker-ce'; then done_case; fi

CASE="disabled or backup Docker sources do not count"
new_env o
printf '# deb https://download.docker.com/linux/ubuntu noble stable\n' >"$T/sources.d/comment.list"
printf 'deb https://download.docker.com/linux/ubuntu noble stable\n' >"$T/sources.d/old.list.save"
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nEnabled: no\n' >"$T/sources.d/disabled.sources"
if run_case "$CASE" 1 has_official_docker_source; then done_case; fi

CASE="active deb822 Docker source is reused"
new_env p
printf 'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\n' >"$T/sources.d/docker.sources"
if run_case "$CASE" 0 has_official_docker_source; then done_case; fi

echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 && "$pass" -eq 16 ]]
