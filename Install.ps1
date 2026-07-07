# ================================
# Install.ps1
# 手动运行：安装 / 卸载 / 覆盖安装（有交互）
# 自动运行：更新 hosts（无交互）
# 自动更新自身（无需 version.txt）
# ================================

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

param(
    [switch]$AutoUpdate
)

$InstallDir = "C:\ProgramData\AmazonHostsUpdater"
$LogDir    = "$InstallDir\logs"
$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$TaskName  = "AmazonHostsUpdater"
$SelfPath  = "$InstallDir\Install.ps1"
$RemoteSelfUrl = "https://gh-proxy.com/https://raw.githubusercontent.com/26eg/GlobalNetSpeedConfigs/main/Install.ps1"

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# ================================
# 自动更新模式（任务计划程序调用）
# ================================
if ($AutoUpdate) {

    $LogFile = "$LogDir\log_{0:yyyyMMdd_HHmmss}.txt" -f (Get-Date)
    "=== 自动更新任务开始 $(Get-Date) ===" | Out-File $LogFile -Encoding utf8

    # 获取 IPv4
    $IPv4 = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp |
             Select-Object -First 1).IPAddress

    if (!$IPv4) {
        "❌ 无有效 IPv4，退出。" | Out-File $LogFile -Append
        exit
    }

    # 调用 IPInfo API
    try {
        $ipinfo = Invoke-RestMethod -Uri "https://ipinfo.io/$IPv4/json" -ErrorAction Stop
    } catch {
        "❌ 无法访问 IPInfo API。" | Out-File $LogFile -Append
        exit
    }

    $Country = $ipinfo.country
    $Region  = $ipinfo.region
    $Org     = $ipinfo.org
    $Hostname = $ipinfo.hostname

    # 判断河南联通
    $IsHN_CU = $false
    if ($Country -eq "CN" -and $Region -match "Henan") {
        if ($Org -match "CHINA UNICOM" -or $Hostname -match "hn") {
            $IsHN_CU = $true
        }
    }

    if (-not $IsHN_CU) {
        "❌ 非河南联通，退出。" | Out-File $LogFile -Append
        exit
    }

    # 下载远程 hosts
    $HostsUrl = "https://raw.githubusercontent.com/你的GitHub用户名/GlobalNetSpeedConfigs/main/hosts_CN_HN_CU_Amazon.txt"
    $TempFile = "$InstallDir\latest_hosts.txt"

    try {
        Invoke-WebRequest -Uri $HostsUrl -OutFile $TempFile -UseBasicParsing
    } catch {
        "❌ 下载远程 hosts 失败。" | Out-File $LogFile -Append
        exit
    }

    # 读取远程时间
    $RemoteTimeLine = Select-String -Path $TempFile -Pattern "^# GENERATED_TIME"
    if (!$RemoteTimeLine) {
        "❌ 远程文件缺少 GENERATED_TIME。" | Out-File $LogFile -Append
        exit
    }

    $RemoteTime = $RemoteTimeLine.ToString().Split(":")[1].Trim()
    $DiffDays = (New-TimeSpan -Start ([datetime]$RemoteTime) -End (Get-Date)).Days

    if ($DiffDays -ge 7) {
        "⚠ 远程文件超过 7 天，不更新。" | Out-File $LogFile -Append
        exit
    }

    # 检查本地 hosts 时间
    $LocalTimeLine = Select-String -Path $HostsFile -Pattern "^# GENERATED_TIME"
    if ($LocalTimeLine) {
        $LocalTime = $LocalTimeLine.ToString().Split(":")[1].Trim()
        $LocalDiff = (New-TimeSpan -Start ([datetime]$LocalTime) -End (Get-Date)).Days

        if ($LocalDiff -ge 14) {
            "⚠ 本地配置超过 14 天，恢复默认 hosts。" | Out-File $LogFile -Append
            $Cleaned = Select-String -Path $HostsFile -Pattern "飞牛NAS自动化测速生成" -NotMatch
            $Cleaned | Set-Content $HostsFile
            exit
        }
    }

    # 更新 hosts
    $Cleaned = Select-String -Path $HostsFile -Pattern "飞牛NAS自动化测速生成" -NotMatch
    $Cleaned | Set-Content $HostsFile
    Add-Content $HostsFile "`n"
    Add-Content $HostsFile (Get-Content $TempFile)

    "✔ hosts 更新成功！" | Out-File $LogFile -Append
    "=== 自动更新任务结束 $(Get-Date) ===" | Out-File $LogFile -Append
    exit
}

# ================================
# 手动运行模式（安装 / 卸载 / 覆盖安装）
# ================================

Write-Host "Amazon Hosts 自动更新客户端"
Write-Host "===================================="
Write-Host ""

# 下载远程 Install.ps1
$RemoteSelfTemp = "$InstallDir\Install_remote.ps1"
Invoke-WebRequest -Uri $ -OutFile $RemoteSelfTemp -UseBasicParsing

# 比对本地与远程 Install.ps1
$LocalContent  = Get-Content $SelfPath -ErrorAction SilentlyContinue
$RemoteContent = Get-Content $RemoteSelfTemp

$Installed = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)

if ($Installed) {

    if ($LocalContent -ne $RemoteContent) {
        Write-Host "检测到 Install.ps1 有新版本。"
        Write-Host "1. 覆盖安装最新版本"
        Write-Host "2. 卸载"
        Write-Host "3. 退出"
        $choice = Read-Host "请输入数字选择"

        switch ($choice) {
            "1" {
                Copy-Item $RemoteSelfTemp $SelfPath -Force
                Write-Host "✔ 已覆盖安装最新版本。"
            }
            "2" {
                Write-Host "正在卸载..."
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
                Remove-Item $InstallDir -Recurse -Force
                Write-Host "✔ 已卸载完成。"
                exit
            }
            "3" { exit }
            default { exit }
        }
    } else {
        Write-Host "已安装且为最新版本。"
        exit
    }
}

# 首次安装
Copy-Item $RemoteSelfTemp $SelfPath -Force

Write-Host "正在创建任务计划程序任务..."

$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$SelfPath`" -AutoUpdate"
$Trigger1 = New-ScheduledTaskTrigger -Daily -At 4:00am
$Trigger2 = New-ScheduledTaskTrigger -AtStartup

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Trigger $Trigger1, $Trigger2 `
    -RunLevel Highest `
    -User "SYSTEM" `
    -Force

Write-Host "✔ 安装完成！"
Write-Host "系统启动后自动运行"
Write-Host "每天 4 点自动更新 hosts"
