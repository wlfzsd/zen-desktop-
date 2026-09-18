#
# 构建上游代理版 Zen（构建 + 打补丁 + 安装 一键脚本）
#
# 功能：从 GitHub 拉取最新（或指定）版本的 zen-desktop 源码，应用上游代理
#       补丁（zen-upstream-chain.patch），构建带上游代理功能的 Zen.exe 并安装。
#       构建使用官方 prod-noupdate 目标（禁用自更新），补丁版不会被自动更新覆盖。
#
# 更新 Zen 后只需重跑本脚本，即可在新版本上重建补丁版（补丁触点极小，
# 冲突时脚本会明确报出冲突文件）。
#
# 用法：
#   .\构建上游代理版Zen.ps1                          # 拉最新 tag 构建+安装
#   .\构建上游代理版Zen.ps1 -Version v0.25.1         # 指定版本
#   .\构建上游代理版Zen.ps1 -UpstreamProxy 1.2.3.4:8080
#       （构建后同时把上游代理写进 Zen 安装目录 upstream-proxy.txt，Zen 启动自动读取）
#   .\构建上游代理版Zen.ps1 -NoInstall               # 只构建不安装
#
# 环境：Windows，需已安装 Go（未装时脚本尝试 winget 安装）与 Node.js。
# 产物日志：logs\构建上游代理版Zen-<时间戳>.log
#

param(
    [string]$Version = "latest",
    [string]$UpstreamProxy = "",
    [string]$RepoDir = "D:\Users\Administrator\Desktop\问题文件夹\zen-desktop",
    [string]$PatchFile = "D:\Users\Administrator\Desktop\问题文件夹\Zen上游代理插件\zen-upstream-chain.patch",
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\Zen",
    [switch]$NoInstall
)

$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date

# ---------- 日志 ----------
$logDir = Join-Path (Split-Path -Parent $PSScriptRoot) "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("构建上游代理版Zen-{0:yyyyMMdd-HHmmss}.log" -f $script:StartTime)

function Write-Log {
    param([string]$Message)
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Exit-Fail {
    param([string]$Message)
    Write-Log "❌ 失败：$Message"
    Write-Host "日志：$logFile" -ForegroundColor Yellow
    exit 1
}

# ---------- 工具定位 ----------
function Get-GoPath {
    $go = Get-Command go -ErrorAction SilentlyContinue
    if ($go) { return $go.Source }
    $candidate = "$env:ProgramFiles\Go\bin\go.exe"
    if (Test-Path $candidate) { return $candidate }
    return $null
}

$goPath = Get-GoPath
if (-not $goPath) {
    Write-Log "未找到 Go，尝试 winget 安装 GoLang.Go ..."
    winget install --id GoLang.Go -e --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Null
    $env:Path = "$env:ProgramFiles\Go\bin;$env:Path"
    $goPath = Get-GoPath
    if (-not $goPath) { Exit-Fail "Go 安装失败，请手动安装后重跑" }
}
# wails 以子进程方式调用 go，必须保证 PATH 里有 Go 的目录
$goDir = Split-Path -Parent $goPath
if (($env:Path -split ';') -notcontains $goDir) {
    $env:Path = "$goDir;$env:Path"
    Write-Log "已将 $goDir 加入本进程 PATH"
}
Write-Log "Go：$(& $goPath version)"

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Exit-Fail "未找到 Node.js（Zen 前端构建需要 node>=24.14）" }
Write-Log "Node：$($node.Source)"

# wails CLI：优先复用脚本目录旁的测试临时 bin，其次 PATH，缺失则编译安装
$wailsCandidates = @(
    "D:\Users\Administrator\Desktop\问题文件夹\测试临时\bin\wails.exe",
    (Join-Path $env:USERPROFILE "go\bin\wails.exe")
)
$wailsExe = $wailsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $wailsExe) {
    $wailsOnPath = Get-Command wails -ErrorAction SilentlyContinue
    if ($wailsOnPath) { $wailsExe = $wailsOnPath.Source }
}
if (-not $wailsExe) {
    Write-Log "未找到 wails CLI，开始编译安装（约 2-5 分钟）..."
    $env:GOTMPDIR = "D:\Users\Administrator\Desktop\问题文件夹\测试临时\gotmp"
    & $goPath install github.com/wailsapp/wails/v2/cmd/wails@v2.14.0
    if ($LASTEXITCODE -ne 0) { Exit-Fail "wails CLI 编译安装失败（网络需可达 goproxy.cn 镜像）" }
    $wailsExe = $wailsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $wailsExe) { Exit-Fail "wails CLI 安装后未找到产物" }
}
Write-Log "wails CLI：$wailsExe"

# Go 模块代理（国内网络直连 proxy.golang.org 通常失败）
$currentProxy = (& $goPath env GOPROXY)
if ($currentProxy -notmatch "goproxy.cn") {
    Write-Log "设置 GOPROXY=https://goproxy.cn,direct（当前：$currentProxy）"
    & $goPath env -w GOPROXY=https://goproxy.cn,direct | Out-Null
}

# ---------- 源码仓库 ----------
if (-not (Test-Path $PatchFile)) { Exit-Fail "补丁文件不存在：$PatchFile" }

if (-not (Test-Path (Join-Path $RepoDir ".git"))) {
    Write-Log "克隆仓库到 $RepoDir ..."
    git clone https://github.com/irbis-sh/zen-desktop.git $RepoDir
    if ($LASTEXITCODE -ne 0) { Exit-Fail "克隆仓库失败" }
}
Set-Location $RepoDir

Write-Log "拉取 tags ..."
git fetch --tags origin 2>$null
if ($LASTEXITCODE -ne 0) {
    # 网络抖动不必然致命：本地已有 tag 时可离线重建（2026-09-18 增强）
    $localTags = git tag | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' }
    if ($localTags) {
        Write-Log "⚠ git fetch 失败（网络），但本地已有版本 tag，降级为离线重建"
    } else {
        Exit-Fail "git fetch --tags 失败（检查网络，且本地无任何版本 tag）"
    }
}

if ($Version -eq "latest") {
    $Version = git tag | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } | ForEach-Object { [version]($_ -replace '^v','') } |
        Sort-Object -Descending | Select-Object -First 1 | ForEach-Object { "v$_" }
    if (-not $Version) { Exit-Fail "未找到任何版本 tag" }
}
Write-Log "目标版本：$Version"

# 仓库目录由本脚本管理：回到干净状态再切 tag（丢弃工作区改动与未跟踪文件）
git reset --hard HEAD | Out-Null
git clean -fd | Out-Null
Write-Log "检出 $Version ..."
git checkout $Version 2>$null
if ($LASTEXITCODE -ne 0) { Exit-Fail "checkout $Version 失败" }

# ---------- 应用补丁 ----------
Write-Log "应用补丁 $(Split-Path -Leaf $PatchFile) ..."
git apply --3way $PatchFile 2>$null
if ($LASTEXITCODE -ne 0) {
    git apply $PatchFile 2>$null
    if ($LASTEXITCODE -ne 0) {
        $conflicts = git status --short | Out-String
        Exit-Fail "补丁应用失败（上游代码变动导致冲突）。冲突状态：`n$conflicts`n处理：对照补丁手工迁移改动点（NewProxy 内 applyUpstreamChain 调用、tunnel 拨号、websocket 两处、upstreamchain.go 新文件）"
    }
}

# 补丁落点自检：新文件 + 挂钩行必须存在（带重试，防杀软扫描新写文件造成的可见性延迟）
if (-not (Test-Path "internal\proxy\upstreamchain.go")) { Exit-Fail "补丁自检失败：upstreamchain.go 不存在" }
$hook = $null
foreach ($attempt in 1..5) {
    $hook = Select-String -Path "internal\proxy\proxy.go" -Pattern "applyUpstreamChain(p)" -SimpleMatch
    if ($hook) { break }
    Write-Log "自检第 $attempt 次未读到挂钩行，1 秒后重试 ..."
    Start-Sleep -Seconds 1
}
if (-not $hook) { Exit-Fail "补丁自检失败：proxy.go 中找不到 applyUpstreamChain 挂钩（补丁内容与上游代码可能不兼容，请核对冲突）" }
Write-Log ("补丁自检通过（挂钩行 proxy.go:{0}）" -f $hook.LineNumber)

# ---------- 构建（官方 prod-noupdate 目标：禁用自更新）----------
$env:GOTMPDIR = "D:\Users\Administrator\Desktop\问题文件夹\测试临时\gotmp"
if (-not (Test-Path $env:GOTMPDIR)) { New-Item -ItemType Directory -Force -Path $env:GOTMPDIR | Out-Null }

$gitTag = git describe --tags --always --abbrev=0
$instanceId = node -e 'const {randomUUID}=require("node:crypto");console.log(randomUUID());'
Write-Log "开始 wails build（GIT_TAG=$gitTag，NoSelfUpdate=true）..."
$buildArgs = @(
    "build", "-o", "Zen.exe", "-platform", "windows/amd64",
    "-ldflags", "-X 'github.com/irbis-sh/zen-desktop/internal/config.Version=$gitTag' -X 'github.com/irbis-sh/zen-desktop/internal/constants.InstanceID=$instanceId' -X 'github.com/irbis-sh/zen-desktop/internal/selfupdate.NoSelfUpdate=true'",
    "-m", "-skipbindings", "-tags", "prod"
)
& $wailsExe @buildArgs 2>&1 | ForEach-Object { Write-Log "  [wails] $_" }
if ($LASTEXITCODE -ne 0) { Exit-Fail "wails build 失败（详见上方 [wails] 行）" }

$builtExe = Join-Path $RepoDir "build\bin\Zen.exe"
if (-not (Test-Path $builtExe)) { Exit-Fail "构建产物不存在：$builtExe" }
$builtInfo = Get-Item $builtExe
Write-Log ("构建完成：{0}（{1:N0} 字节）" -f $builtExe, $builtInfo.Length)

# ---------- 安装 ----------
if ($NoInstall) {
    Write-Log "-NoInstall：仅构建，不安装。产物：$builtExe"
} else {
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    }
    $targetExe = Join-Path $InstallDir "Zen.exe"

    # 停止正在运行的 Zen：按记录的 PID 精准停止（先优雅关闭窗口）
    $zenProcs = @(Get-Process -Name "Zen" -ErrorAction SilentlyContinue)
    foreach ($proc in $zenProcs) {
        Write-Log ("发现运行中的 Zen（PID={0}，启动于 {1}），尝试优雅关闭 ..." -f $proc.Id, $proc.StartTime)
        $null = $proc.CloseMainWindow()
        if (-not $proc.WaitForExit(5000)) {
            Write-Log "优雅关闭超时，按 PID 精准终止 ..."
            Stop-Process -Id $proc.Id -Force
            $proc.WaitForExit(3000) | Out-Null
        }
    }

    # 备份现有 exe（带版本与时间戳，防止覆盖丢失）
    if (Test-Path $targetExe) {
        $backupDir = Join-Path $InstallDir "backup"
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
        $backupFile = Join-Path $backupDir ("Zen-{0}.exe.bak-{1:yyyyMMdd-HHmmss}" -f $Version, (Get-Date))
        Copy-Item $targetExe $backupFile -Force
        $srcHash = (Get-FileHash $targetExe -Algorithm SHA256).Hash
        $bakHash = (Get-FileHash $backupFile -Algorithm SHA256).Hash
        if ($srcHash -ne $bakHash) { Exit-Fail "备份校验不一致，中止安装（$backupFile）" }
        Write-Log "已备份原版：$backupFile"
    }

    Copy-Item $builtExe $targetExe -Force
    if ((Get-FileHash $targetExe -Algorithm SHA256).Hash -ne (Get-FileHash $builtExe -Algorithm SHA256).Hash) {
        Exit-Fail "安装校验失败：目标文件与构建产物哈希不一致"
    }
    Write-Log ("已安装补丁版：{0}（{1:N0} 字节）" -f $targetExe, (Get-Item $targetExe).Length)
}

# ---------- 上游代理配置（写入 Zen 安装目录配置文件，零环境变量——规则17 2026-09-17/18） ----------
if ($UpstreamProxy -ne "") {
    $instDir = @((Join-Path $env:LOCALAPPDATA 'Programs\Zen'), (Join-Path $env:ProgramFiles 'Zen')) |
        Where-Object { $_ -and (Test-Path (Join-Path $_ 'Zen.exe')) } | Select-Object -First 1
    if (-not $instDir) { Exit-Fail "未找到 Zen 安装目录，无法写 upstream-proxy.txt" }
    # Select-Object -First 1 防单结果标量化（$x[0] 会取到字符串首字符，2026-09-18 踩坑）
    $cfgFile = Join-Path $instDir "upstream-proxy.txt"
    [System.IO.File]::WriteAllText($cfgFile, $UpstreamProxy + "`r`n", [System.Text.Encoding]::ASCII)
    Write-Log "已写入上游代理配置文件 $cfgFile=$UpstreamProxy（Zen 启动时自动读取，任意启动方式生效，零持久环境变量）"
}

$elapsed = (Get-Date) - $script:StartTime
Write-Log ("✅ 全部完成，用时 {0:mm}分{1:ss}秒。日志：{2}" -f $elapsed, $elapsed, $logFile)
Write-Host ""
Write-Host "后续：启动 Zen 即生效。改上游代理地址运行 .\设置上游代理.ps1 -Proxy <ip:端口>" -ForegroundColor Green
