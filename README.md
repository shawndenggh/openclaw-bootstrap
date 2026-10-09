# OpenClaw Ubuntu 一键安装脚本

这是一个面向 **Ubuntu** 的小型 Bash 安装脚本，用于公开 GitHub 仓库中的 **OpenClaw 一键安装**。

脚本文件：`install.sh`

## 适用范围

- 需要 **Bash**，请使用 `bash` 执行，不要用 `sh`
- 仅支持 **Ubuntu**
- 仅支持 `x86_64` 与 `aarch64`
- 负责确保 **Docker Engine** 与 **Docker Compose v2** 可用，安装 OpenClaw，并可选启动一次 `openclaw onboard`

如果系统里已经存在 `openclaw`，脚本会直接跳过安装，**不会升级，也不会覆盖现有配置**。但显式指定 `--onboard` 时仍会运行 `openclaw onboard`，该向导可能有意修改配置，上述“跳过安装”的承诺不适用于这个显式请求的向导。

未指定 `--onboard` 时，脚本结束前会提示后续步骤：先运行 `openclaw onboard`，再运行 `openclaw gateway install`（已安装与全新安装两种情况均适用）。

## Docker / Compose 自动安装

脚本默认**先**确保 Docker 与 Compose v2 可用，再处理 OpenClaw，因此即使 `openclaw` 已存在，重新运行也会补装缺失的 Docker。

- Compose 指 v2 插件，命令为 `docker compose`（**不是**旧版 `docker-compose`）。
- `docker --version` 与 `docker compose version` 都正常：不安装任何 Docker 软件包，不改动服务，也不需要 sudo。
- 已有 Docker 但缺少 Compose v2：仅安装兼容的 Compose 软件包（优先 `docker-compose-plugin`，其次 `docker-compose-v2`，都没有时使用 Docker 官方 Ubuntu apt 源）。安装前会用 `apt-get -s` 模拟，若会移除软件包或触及已有 Docker/containerd/runc 等引擎核心包则拒绝。**现有引擎保持不变**，不会被重装、升级或重启。
- 完全没有 Docker：使用官方源 `https://download.docker.com/linux/ubuntu`（密钥经 HTTPS 下载，apt `signed-by` 方式校验）安装 `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`。已存在官方源则复用；否则写入 `/etc/apt/sources.list.d/openclaw-bootstrap-docker.sources` 与 `/etc/apt/keyrings/openclaw-bootstrap-docker.asc`，不会覆盖未知的同名文件。
- 全新安装后，若 systemd 正在运行则执行 `systemctl enable --now docker`；否则脚本会提示服务未自动启动，需自行启动。
- 若检测到 `docker.io`、`docker-compose`、`docker-compose-v2`、`docker-doc`、`docker-buildx`、`podman-docker`、`containerd`、`runc` 等冲突软件包、残留的部分 Docker CE 软件包、无法运行的 `docker` 命令或 Podman 兼容层，脚本会给出中文提示并退出，**不会卸载或替换**。
- 不会删除任何数据，不执行 autoremove/prune，不下载 hello-world 测试镜像。
- 不会自动把用户加入 `docker` 组，不修改 `daemon.json`，也不手动改防火墙；Docker 自身会管理其网络规则。初始登录用户可能需要使用 `sudo docker`，或自行配置访问权限，才能让沙箱使用 Docker。
- 需要 root 或免密 `sudo -n` 才会写入 apt 配置或安装软件包；无法提权时请先运行 `sudo -v` 后重试。

## 安装与后续配置的区别

这个脚本的职责是：

- 检查 Ubuntu / 架构
- 在缺少时安装所需依赖：`ca-certificates`、`curl`、`git`
- 确保 Docker Engine 与 Docker Compose v2（见上文）
- 下载并执行 OpenClaw 官方安装器
- 可选执行 `openclaw onboard`

这个脚本 **不等于** 完整的 OAuth、频道接入或服务部署自动化。下面这些事情仍然需要你在安装后按自己的环境完成：

- OAuth / 登录授权
- 频道接入与令牌准备
- Gateway / Service 安装与部署

换句话说：**安装 CLI** 和 **完成账号、频道、服务配置** 是两件不同的事。

## 一行安装

下面的 `curl ... | bash` 命令本身需要 `curl` 才能引导。最小化 Ubuntu 请先执行：

```bash
sudo apt-get update && sudo apt-get install -y curl ca-certificates
```

请在预期运行服务的登录用户下执行，**不要**使用 `sudo bash` 运行本脚本。官方安装器安装 Node 时也可能需要 `sudo`。

默认安装最新版本：

```bash
curl -fsSL https://raw.githubusercontent.com/shawndenggh/openclaw-bootstrap/main/install.sh | bash
```

指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/shawndenggh/openclaw-bootstrap/main/install.sh | bash -s -- --version 2026.9.6
```

安装后立即进入交互式引导：

```bash
curl -fsSL https://raw.githubusercontent.com/shawndenggh/openclaw-bootstrap/main/install.sh | bash -s -- --onboard
```

同时指定版本并执行引导：

```bash
curl -fsSL https://raw.githubusercontent.com/shawndenggh/openclaw-bootstrap/main/install.sh | bash -s -- --version 2026.9.6 --onboard
```

## 可选：先下载，再检查，再执行

如果你希望先审阅脚本内容，可以这样做：

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/shawndenggh/openclaw-bootstrap/main/install.sh
chmod +x install.sh
less install.sh
./install.sh
```

指定版本或启用引导时同样适用：

```bash
./install.sh --version 2026.9.6
./install.sh --onboard
```

## `--onboard` 的说明

`--onboard` 会在安装成功后执行：

```bash
openclaw onboard
```

为了兼容 `curl ... | bash -s -- --onboard` 这种用法，脚本会尝试从 `/dev/tty` 读取交互输入。

如果当前环境没有可用的交互终端（例如某些 CI、后台任务或被严格重定向的环境），脚本会停止并提示你改为：

1. 先安装 OpenClaw
2. 在可交互终端中运行 `openclaw onboard`
3. 完成 OpenClaw Gateway 配置后运行 `openclaw gateway install`

## 依赖与实现说明

脚本只会在需要安装依赖、Docker 或 Compose 时才请求 `root` 或 `sudo` 权限；全部已就绪时不会提权。

它会检查并按需安装：

- `ca-certificates`
- `curl`
- `git`

随后脚本会从下面的官方地址下载安装器：

```text
https://openclaw.ai/install.sh
```

并使用以下参数执行官方安装器：

```text
--install-method npm --version <版本> --no-prompt --no-onboard
```

兼容的 Node.js 处理由 **官方安装器** 负责，这个仓库里的脚本 **不会硬编码 Node 版本**。

## 测试

`tests/test-install.sh` 使用完全模拟的命令验证 Docker/Compose 逻辑，不会执行真实安装：

```bash
bash tests/test-install.sh
```

## 帮助

```bash
bash install.sh --help
```

## 重要提醒

- 本脚本不会自动声明“认证已全部完成”
- 本脚本不会替你自动完成频道接入或服务部署
- 如需部署 Gateway / Service，请在完成 `openclaw onboard` 和相关配置后，按官方流程继续执行
