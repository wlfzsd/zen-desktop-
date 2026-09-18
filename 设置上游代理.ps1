#
# 设置 Zen 上游代理（写入 Zen 安装目录 upstream-proxy.txt——零环境变量）
#
# 用法：
#   .\设置上游代理.ps1 -Proxy 1.2.3.4:8080          # 启用（HTTP 代理）
#   .\设置上游代理.ps1 -Proxy http://1.2.3.4:8080   # 同上，显式协议
#   .\设置上游代理.ps1 -Proxy http://user:pass@1.2.3.4:8080   # 带认证
#   .\设置上游代理.ps1 -Clear                       # 关闭上游代理（恢复直连）
#   .\设置上游代理.ps1                              # 查看当前配置
#
# 说明：只接受 HTTP 代理。配置文件放在 Zen.exe 同目录，Zen 启动时自动读取
#       （任意启动方式均生效；环境变量 ZEN_UPSTREAM_PROXY 可临时覆盖，优先级更高）。
#       改动后重启 Zen 生效。
#
# 2026-09-18：配置迁移到 Zen 安装目录（启动器不再是必需环节）
#

param(
    [string]$Proxy = "",
    [switch]$Clear
)

# 定位 Zen 安装目录（与安装/启动逻辑一致）
# 注意：Where-Object 只剩一个结果时会标量化，必须 Select-Object -First 1，
# 否则 $x[0] 取到的是字符串首字符（踩坑实录：cfgFile 变成 "C\upstream-proxy.txt"）
$instDir = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Zen'),
    (Join-Path $env:ProgramFiles 'Zen')
) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'Zen.exe')) } | Select-Object -First 1
if (-not $instDir) {
    Write-Host "❌ 未找到 Zen 安装目录（先运行 构建上游代理版Zen.ps1）" -ForegroundColor Red
    exit 1
}
$cfgFile = Join-Path $instDir "upstream-proxy.txt"

if ($Clear) {
    if (Test-Path $cfgFile) { Remove-Item $cfgFile -Force }
    Write-Host "✅ 已清除上游代理配置（Zen 恢复直连），重启 Zen 生效" -ForegroundColor Green
    exit 0
}

if ($Proxy -eq "") {
    if (Test-Path $cfgFile) {
        Write-Host "当前上游代理：$((Get-Content $cfgFile -Raw).Trim())  （$cfgFile）"
    } else {
        Write-Host "当前未设置上游代理（直连模式）。用法：.\设置上游代理.ps1 -Proxy <ip:端口>"
    }
    exit 0
}

# 规范化：允许裸 ip:port；只允许 http 代理
$v = $Proxy.Trim()
if ($v -notmatch "://") { $v = "http://" + $v }
$u = $null
try { $u = [Uri]$v } catch { }
if (-not $u -or $u.Scheme -ne "http" -or -not $u.Host) {
    Write-Host "❌ 无效地址：$Proxy（只支持 http://ip:端口，或裸 ip:端口）" -ForegroundColor Red
    exit 1
}

$value = $u.AbsoluteUri.TrimEnd('/')
# ASCII 无 BOM 写入（Zen 按字节读取并容忍 BOM，纯 ASCII 最稳）
[System.IO.File]::WriteAllText($cfgFile, $value + "`r`n", [System.Text.Encoding]::ASCII)
Write-Host "✅ 已设置上游代理：$value" -ForegroundColor Green
Write-Host "配置位置：$cfgFile"
Write-Host "生效方式：重启 Zen（任意启动方式均可，开始菜单/桌面/托盘皆可）"
Write-Host "当前值可随时用以下命令核对（或直接运行本脚本不带参数）："
Write-Host "  Get-Content '$cfgFile'"
