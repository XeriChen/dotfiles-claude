#Requires -Version 7.0
<#
.SYNOPSIS
    修复 dsh 插件「装不上」与「装了不生效」两类故障（默认目标：dsh-purge）。

.DESCRIPTION
    把 2026-10-02 那次手工排查固化成可重放的脚本。故障其实是两条独立链路：

    1. 装错 profile（症状：装完毫无反应）
       官方 DeepSeek Harness 桌面版把 profile 名硬编码成 desktop —— 宿主主进程里直接拼
       dshHome/profiles/desktop。插件 README 给的 --profile default 对本版本是过时的，
       装进 default 的插件永远不会被加载。

    2. pnpm 拒绝安装（症状：add 命令报错退出）
       tarball 命中本地 store 复用时（reused 1 / downloaded 0），pnpm 写出的 lockfile
       条目缺少 integrity 字段，随后报：
         [ERR_PNPM_MISSING_TARBALL_INTEGRITY] its lockfile entry has no "integrity" field
       处理办法：先让 pnpm 跑一次生成条目骨架，再把 integrity 补进这条条目，然后重跑安装。

    脚本只写 profile 目录下的 package.json / pnpm-lock.yaml，不动 prompt-inject.md，
    也不删除任何文件；任何改动前整份备份到 $DshHome\plugin-backups\。

.PARAMETER PluginUrl
    插件 tarball 地址。默认 dsh-purge 的 gh-proxy 镜像。

.PARAMETER PluginName
    npm 包名，用于查 dependencies / bundles / node_modules。默认 dsh-purge。

.PARAMETER Profile
    目标 profile。缺省取 $env:DSH_PROFILE；取不到时若 profiles\desktop 存在则用 desktop。

.PARAMETER DshHome
    DSH 家目录。缺省取 $env:DSH_HOME，再缺省 $env:USERPROFILE\.dsh。

.PARAMETER Check
    只体检，不做任何改动：报告插件是否装上、profile 是否装错、lockfile 有没有 integrity。

.PARAMETER Force
    即使插件已安装，也重跑一次安装命令。

.EXAMPLE
    pwsh -File .\fix-dsh-plugin-install.ps1 -Check

.EXAMPLE
    pwsh -File .\fix-dsh-plugin-install.ps1

.NOTES
    本文件是 UTF-8（无 BOM），请用 PowerShell 7+ 运行。
    写 $DshHome 属于工作区之外的路径，需要 DSH 文件策略为 danger-full-access。
#>

[CmdletBinding()]
param(
    [string]$PluginUrl = 'https://v4.gh-proxy.org/https://github.com/YuJunZhiXue/dsh-purge/archive/refs/heads/master.tar.gz',
    [string]$PluginName = 'dsh-purge',
    [string]$Profile,
    [string]$DshHome,
    [switch]$Check,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Section([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "  [--]   $Text" -ForegroundColor DarkGray }
function Write-WarnLine([string]$Text) { Write-Host "  [warn] $Text" -ForegroundColor Yellow }
function Write-FailLine([string]$Text) { Write-Host "  [fail] $Text" -ForegroundColor Red }

# 定位 dsh CLI：优先 PATH，其次官方桌面版的内置 runtime。
function Resolve-DshCli {
    $cmd = Get-Command dsh -CommandType Application -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($env:LOCALAPPDATA) {
        $guess = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd'
        if (Test-Path $guess) { return $guess }
    }
    return $null
}

# profile 名 = profiles 下的目录名（desktop / default / web ...）。
function Resolve-Profile([string]$Requested, [string]$DshRoot) {
    if ($Requested) { return $Requested }
    if ($env:DSH_PROFILE) { return $env:DSH_PROFILE }
    if (Test-Path (Join-Path $DshRoot 'profiles\desktop\package.json')) { return 'desktop' }
    return 'default'
}

function Get-Manifest([string]$ProfileDir) {
    $file = Join-Path $ProfileDir 'package.json'
    if (-not (Test-Path $file)) { return $null }
    return (Get-Content $file -Raw | ConvertFrom-Json)
}

# 汇总某个 profile 里该插件的三处登记：依赖、bundle、node_modules。
function Get-InstallState([string]$ProfileDir, [string]$Name) {
    $manifest = Get-Manifest $ProfileDir
    $dep = $false
    $bundle = $false
    if ($manifest) {
        if ($manifest.PSObject.Properties['dependencies']) {
            $dep = @($manifest.dependencies.PSObject.Properties.Name) -contains $Name
        }
        $dsh = $manifest.PSObject.Properties['dsh']
        if ($dsh -and $manifest.dsh.PSObject.Properties['profile'] -and $manifest.dsh.profile.PSObject.Properties['bundles']) {
            $bundle = @($manifest.dsh.profile.bundles) -contains $Name
        }
    }
    $moduleDir = Join-Path $ProfileDir "node_modules\$Name"
    $version = $null
    $moduleJson = Join-Path $moduleDir 'package.json'
    if (Test-Path $moduleJson) {
        $version = (Get-Content $moduleJson -Raw | ConvertFrom-Json).version
    }
    return [pscustomobject]@{
        Dependency = $dep
        Bundle     = $bundle
        Module     = (Test-Path $moduleDir)
        Version    = $version
        Installed  = ($dep -and $bundle -and (Test-Path $moduleDir))
    }
}

# 在 lockfile 里找到 <name>@<url> 这个包块，返回块内第一处 integrity。
function Get-LockfileIntegrity([string]$LockfilePath, [string]$Url) {
    if (-not (Test-Path $LockfilePath)) { return $null }
    $lines = @(Get-Content $LockfilePath)
    $keyIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # 包块首行形如 "  dsh-purge@https://...:"；importers 段的 "dsh-purge:" 不含 url，天然被排除。
        if ($lines[$i].TrimEnd().EndsWith(':') -and $lines[$i].Contains($Url)) { $keyIdx = $i; break }
    }
    if ($keyIdx -lt 0) { return $null }

    $keyIndent = $lines[$keyIdx].Length - $lines[$keyIdx].TrimStart().Length
    for ($j = $keyIdx + 1; $j -lt $lines.Count; $j++) {
        $line = $lines[$j]
        if (-not $line.Trim()) { continue }
        if (($line.Length - $line.TrimStart().Length) -le $keyIndent) { break }  # 出了这个块
        if ($line -match 'integrity:\s*(sha\d+-[A-Za-z0-9+/=]+)') { return $Matches[1] }
    }
    return $null
}

# 把 integrity 补进 lockfile 的 resolution。兼容 pnpm 的单行 map 与多行写法。
function Set-LockfileIntegrity([string]$LockfilePath, [string]$Url, [string]$Integrity) {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in @(Get-Content $LockfilePath)) { $lines.Add($l) }

    $keyIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimEnd().EndsWith(':') -and $lines[$i].Contains($Url)) { $keyIdx = $i; break }
    }
    if ($keyIdx -lt 0) { return $false }

    $keyIndent = $lines[$keyIdx].Length - $lines[$keyIdx].TrimStart().Length
    for ($j = $keyIdx + 1; $j -lt $lines.Count; $j++) {
        $line = $lines[$j]
        if (-not $line.Trim()) { continue }
        $indent = $line.Length - $line.TrimStart().Length
        if ($indent -le $keyIndent) { break }
        if ($line -notmatch '^\s*resolution:') { continue }

        if ($line -match 'integrity:') { return $true }                     # 已经有了
        $pad = ' ' * $indent
        if ($line -match '^\s*resolution:\s*\{(.*)\}\s*$') {                # resolution: {tarball: url}
            $lines[$j] = $pad + 'resolution: {integrity: ' + $Integrity + ', ' + $Matches[1] + '}'
            [System.IO.File]::WriteAllLines($LockfilePath, $lines, [System.Text.UTF8Encoding]::new($false))
            return $true
        }
        if ($line.Trim() -eq 'resolution:') {                               # resolution:\n  tarball: url
            $lines.Insert($j + 1, (' ' * ($indent + 2)) + "integrity: $Integrity")
            [System.IO.File]::WriteAllLines($LockfilePath, $lines, [System.Text.UTF8Encoding]::new($false))
            return $true
        }
    }
    return $false
}

# 兜底：没有别的 profile 可抄时，直接下载 tarball 算 SRI（pnpm 的 integrity 就是 tarball 字节的 sha512 base64）。
function Get-TarballIntegrity([string]$Url) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-plugin-' + [guid]::NewGuid().ToString('N') + '.tgz')
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tmp
        $sha = [System.Security.Cryptography.SHA512]::Create()
        try { $hash = $sha.ComputeHash([System.IO.File]::ReadAllBytes($tmp)) } finally { $sha.Dispose() }
        return 'sha512-' + [Convert]::ToBase64String($hash)
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Test-Writable([string]$Dir) {
    $probe = Join-Path $Dir ('.dsh-write-probe-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probe, 'probe', [System.Text.UTF8Encoding]::new($false))
        Remove-Item $probe -Force
        return $true
    } catch {
        return $false
    }
}

function Invoke-PluginAdd([string]$DshCli, [string]$TargetProfile, [string]$Url) {
    $text = & $DshCli plugin --profile $TargetProfile add $Url 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $text.Trim() }
}

function Backup-Profile([string]$ProfileDir, [string]$DshRoot, [string]$Name) {
    $dir = Join-Path $DshRoot ('plugin-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $Name)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($f in 'package.json', 'pnpm-lock.yaml', 'cordis.patch.yml', 'pnpm-workspace.yaml') {
        $src = Join-Path $ProfileDir $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $dir $f) -Force }
    }
    return $dir
}

# ---------------------------------------------------------------- 主流程

if (-not $DshHome) {
    $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
}
$Profile = Resolve-Profile -Requested $Profile -DshRoot $DshHome
$profileDir = Join-Path $DshHome "profiles\$Profile"
$lockfile = Join-Path $profileDir 'pnpm-lock.yaml'

Write-Section '0. 环境'
Write-Note "DSH_HOME : $DshHome"
Write-Note "profile  : $Profile  ($profileDir)"
Write-Note "插件     : $PluginName"
Write-Note "地址     : $PluginUrl"

if (-not (Test-Path (Join-Path $profileDir 'package.json'))) {
    Write-FailLine "profile 目录不存在或没有 package.json：$profileDir"
    Write-FailLine '确认 -Profile / -DshHome，或先跑一次 dsh 让它生成该 profile。'
    exit 1
}
$dshCli = Resolve-DshCli
if ($dshCli) { Write-Ok "dsh CLI  : $dshCli" } else { Write-WarnLine 'PATH 里没有 dsh，无法执行安装（体检不受影响）' }

# --- 1. 体检：当前 profile 装没装；别的 profile 是不是装错地方了 -----------------
Write-Section '1. 体检'
$state = Get-InstallState -ProfileDir $profileDir -Name $PluginName
Write-Note ("依赖 {0} / bundle {1} / node_modules {2}" -f $state.Dependency, $state.Bundle, $state.Module)
if ($state.Installed) {
    Write-Ok "已装在 $Profile profile（版本 $($state.Version)）"
} else {
    Write-WarnLine "在 $Profile profile 里没有完整登记"
}

# 经典症状：插件装在 default，而宿主实际跑的是 desktop —— 这是「装了没反应」的头号原因。
# 只在当前 profile 没装、别的 profile 装了时才报，否则一个正常的双 profile 环境会被误伤。
if (-not $state.Installed) {
    foreach ($other in Get-ChildItem (Join-Path $DshHome 'profiles') -Directory -ErrorAction SilentlyContinue) {
        if ($other.Name -eq $Profile) { continue }
        $otherState = Get-InstallState -ProfileDir $other.FullName -Name $PluginName
        if ($otherState.Installed) {
            Write-WarnLine "插件其实装在 '$($other.Name)' profile 里，而当前宿主用的是 '$Profile' profile —— 装错位置，永远不会加载"
        }
    }
}

$existingIntegrity = Get-LockfileIntegrity -LockfilePath $lockfile -Url $PluginUrl
if ($existingIntegrity) { Write-Ok "lockfile integrity: $existingIntegrity" }
else { Write-WarnLine 'lockfile 里还没有带 integrity 的条目' }

if ($Check) {
    Write-Section '结束'
    Write-Note '-Check 模式，未做任何改动。'
    exit 0
}

if ($state.Installed -and -not $Force) {
    Write-Section '结束'
    Write-Ok '插件已就位，无需重装。加 -Force 可强制重跑安装命令。'
    exit 0
}

if (-not $dshCli) {
    Write-Section '失败'
    Write-FailLine '没有可用的 dsh CLI，安装命令无法执行。'
    exit 1
}

if (-not (Test-Writable -Dir $profileDir)) {
    Write-Section '失败'
    Write-FailLine "无法写入 $profileDir"
    Write-FailLine '该路径在工作区之外，需要 DSH 文件策略为 danger-full-access（或让宿主以全权限运行）。'
    exit 1
}

# --- 2. 先备份 ---------------------------------------------------------------
Write-Section '2. 备份'
$backupDir = Backup-Profile -ProfileDir $profileDir -DshRoot $DshHome -Name $PluginName
Write-Ok "备份到 $backupDir"
Write-Note '要回滚就把这里的文件拷回 profile 目录。'

# --- 3. 第一次尝试：直接装 ----------------------------------------------------
Write-Section '3. 第一次尝试安装'
$first = Invoke-PluginAdd -DshCli $dshCli -TargetProfile $Profile -Url $PluginUrl
Write-Note "退出码 $($first.ExitCode)"
if ($first.Output) { Write-Host ($first.Output -split "`r?`n" | ForEach-Object { "         $_" }) -ForegroundColor DarkGray }

$state = Get-InstallState -ProfileDir $profileDir -Name $PluginName
if ($state.Installed) {
    Write-Ok "安装成功（版本 $($state.Version)）"
} else {
    # --- 4. 命中缺 integrity 的已知坑：补齐后再试 ------------------------------
    Write-Section '4. 补 lockfile integrity'
    if ($first.Output -notmatch 'MISSING_TARBALL_INTEGRITY') {
        Write-FailLine '失败原因不是已知的 integrity 问题，请按上面的输出排查。'
        Write-Note "pnpm 日志：$profileDir\.plugin-manager\logs\"
        exit 2
    }
    Write-WarnLine 'pnpm 复用了 store 里的 tarball，写出的 lockfile 条目没有 integrity 字段。'

    # 先抄别的 profile 里现成的 integrity（不用联网），抄不到再下载 tarball 现算。
    $integrity = $null
    foreach ($other in Get-ChildItem (Join-Path $DshHome 'profiles') -Directory -ErrorAction SilentlyContinue) {
        if ($other.Name -eq $Profile) { continue }
        $found = Get-LockfileIntegrity -LockfilePath (Join-Path $other.FullName 'pnpm-lock.yaml') -Url $PluginUrl
        if ($found) {
            $integrity = $found
            Write-Ok "从 '$($other.Name)' profile 的 lockfile 抄到：$integrity"
            break
        }
    }
    if (-not $integrity) {
        Write-Note '没有可抄的 lockfile，改为下载 tarball 现算 sha512……'
        $integrity = Get-TarballIntegrity -Url $PluginUrl
        Write-Ok "算出：$integrity"
    }

    if (-not (Set-LockfileIntegrity -LockfilePath $lockfile -Url $PluginUrl -Integrity $integrity)) {
        Write-FailLine "lockfile 里找不到 $PluginName 的包块，无法就地补字段。"
        Write-Note "请先跑一次安装让它生成条目骨架，或删除 $lockfile 后重试。"
        exit 2
    }
    Write-Ok '已将 integrity 写入 lockfile 的 resolution 字段'

    # --- 5. 重试 -------------------------------------------------------------
    Write-Section '5. 重试安装'
    $second = Invoke-PluginAdd -DshCli $dshCli -TargetProfile $Profile -Url $PluginUrl
    Write-Note "退出码 $($second.ExitCode)"
    if ($second.Output) { Write-Host ($second.Output -split "`r?`n" | ForEach-Object { "         $_" }) -ForegroundColor DarkGray }
    $state = Get-InstallState -ProfileDir $profileDir -Name $PluginName
    if (-not $state.Installed) {
        Write-FailLine '仍然失败，原始状态已备份，可直接回滚。'
        Write-Note "pnpm 日志：$profileDir\.plugin-manager\logs\"
        exit 2
    }
    Write-Ok "安装成功（版本 $($state.Version)）"
}

# --- 6. 校验 ----------------------------------------------------------------
Write-Section '6. 校验'
$manifest = Get-Manifest $profileDir
$bundleCount = @($manifest.dsh.profile.bundles).Count
Write-Ok "dependencies 含 $PluginName / bundles（$bundleCount 项）含 $PluginName / node_modules\$PluginName 在位"
$finalIntegrity = Get-LockfileIntegrity -LockfilePath $lockfile -Url $PluginUrl
if ($finalIntegrity) { Write-Ok "lockfile integrity: $finalIntegrity" } else { Write-WarnLine 'lockfile 仍无 integrity（安装已成功，属遗留状态）' }

# --- 7. 装完还不算生效 ------------------------------------------------------
Write-Section '7. 还差一步（脚本不做，需人工）'
Write-Note '1) 重启宿主。bundle 只在启动时加载，当前进程看不到新插件。'
Write-Note '2) 在插件设置里点一次「应用」。dsh-purge 这类会改宿主文件的插件，仅安装不会生效。'
Write-WarnLine "回滚用的备份在：$backupDir"

exit 0
