# OpenClaw Ubuntu 一键安装脚本

这是一个面向 **Ubuntu** 的小型 Bash 安装脚本，用于公开 GitHub 仓库中的 **OpenClaw 一键安装**。

脚本文件：`install.sh`

## 适用范围

- 需要 **Bash**，请使用 `bash` 执行，不要用 `sh`
- 仅支持 **Ubuntu**
- 仅支持 `x86_64` 与 `aarch64`
- 仅负责安装 OpenClaw，并可选启动一次 `openclaw onboard`

如果系统里已经存在 `openclaw`，脚本会直接跳过安装，**不会升级，也不会覆盖现有配置**。但显式指定 `--onboard` 时仍会运行 `openclaw onboard`，该向导可能有意修改配置，上述“跳过安装”的承诺不适用于这个显式请求的向导。

未指定 `--onboard` 时，脚本结束前会提示后续步骤：先运行 `openclaw onboard`，再运行 `openclaw gateway install`（已安装与全新安装两种情况均适用）。

## 安装与后续配置的区别

这个脚本的职责是：

- 检查 Ubuntu / 架构
- 在缺少时安装安装器所需依赖：`ca-certificates`、`curl`、`git`
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

脚本只会在缺少依赖时才请求 `root` 或 `sudo` 权限。

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

## 帮助

```bash
bash install.sh --help
```

## 重要提醒

- 本脚本不会自动声明“认证已全部完成”
- 本脚本不会替你自动完成频道接入或服务部署
- 如需部署 Gateway / Service，请在完成 `openclaw onboard` 和相关配置后，按官方流程继续执行
