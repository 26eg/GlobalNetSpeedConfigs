#Requires -Version 5.1 
# GlobalNetSpeedConfigs 单文件脚本 gnsc.ps1 
# 无参数 = 安装/升级/卸载引导；-Worker = 计划任务每日执行 
param([switch]$Worker) 
 
# ===== 全局配置 ===== 
$ScriptVersion = '1.0.0' 
$AppName    = 'GlobalNetSpeedConfigs' 
$Base       = 'https://gnsc.aioz.cc'  # 可替换为自建 Cloudflare 加速域名 
$SelfUrl    = "$Base/gnsc.ps1" 
$InstallDir = Join-Path $env:ProgramData $AppName 
$SelfPath   = Join-Path $InstallDir 'gnsc.ps1' 
$TaskName   = $AppName 
$RunTime    = '04:00' 
$HostsPath  = "$env:WINDIR\System32\drivers\etc\hosts" 
$Tag        = $AppName 
$BeginMark  = "# >>> $Tag BEGIN >>>" 
$EndMark    = "# <<< $Tag END <<<" 
$MaxAgeDays = 14 
$Business   = 'Amazon' 
 
# ========================================================= 
# Worker 分支：计划任务每天以 SYSTEM 调用（gnsc.ps1 -Worker） 
# ========================================================= 
function Invoke-Worker { 
  # (可选) 脚本自更新：在线版本号更新则静默替换自身 
  try { 
    $online = (Invoke-WebRequest -UseBasicParsing $SelfUrl).Content 
    if ($online -match "\`$ScriptVersion\s*=\s*'([^']+)'") { 
      if ([version]$Matches[1] -gt [version]$ScriptVersion) { Set-Content $SelfPath $online -Encoding UTF8 } 
    } 
  } catch {} 
 
  # 1) 本地 IPv4；无则终止 
  $ipv4 = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | 
    Sort-Object SkipAsSource | Select-Object -First 1).IPAddress 
  if (-not $ipv4) { return } 
 
  # 2) 解析归属，拼接配置文件名 
  $cfgName = $null 
  try { 
    $info = Invoke-RestMethod "https://ipinfo.io/$ipv4/json" -TimeoutSec 15 
    $rc  = if ($info.region -match 'Henan') { 'HN' } else { ($info.region -replace '\W','').Substring(0,2).ToUpper() } 
    $isp = if     ($info.org -match 'UNICOM')  { 'CU' } 
        elseif ($info.org -match 'TELECOM') { 'CT' } 
        elseif ($info.org -match 'MOBILE')  { 'CM' } 
        else { 'XX' } 
    $cfgName = "hosts_$($info.country)_${rc}_${isp}_${Business}.txt"  # 例：hosts_CN_HN_CU_Amazon.txt 
  } catch { $cfgName = $null } 
 
  # 3) 工具函数（时间戳复用配置文件里的 GENERATED_TIME） 
  $raw = Get-Content $HostsPath -Raw -ErrorAction SilentlyContinue 
  $hasBlock = $raw -match [regex]::Escape($BeginMark) 
  function Get-Ts { param($t) 
    if ($t -match "$([regex]::Escape($BeginMark))\s*\r?\n# GENERATED_TIME:\s*(.+)") { 
      try { [datetime]::Parse($Matches[1].Trim()) } catch { $null } } else { $null } } 
  function Remove-Block { param($t) 
    [regex]::Replace($t, "(?s)\r?\n?$([regex]::Escape($BeginMark)).*?$([regex]::Escape($EndMark))\r?\n?", '') } 
  function Write-Hosts { param($t) Set-Content -Path $HostsPath -Value $t -Encoding ASCII; ipconfig /flushdns | Out-Null } 
 
  # 4) 拉取在线配置 
  $onlineText=$null; $onlineTs=$null; $onlineOk=$false 
  if ($cfgName) { 
    try { 
      $onlineText = (Invoke-WebRequest -UseBasicParsing "$Base/$cfgName").Content 
      if ($onlineText -match '# GENERATED_TIME:\s*(.+)') { $onlineTs = [datetime]::Parse($Matches[1].Trim()) } 
      $onlineOk = $true 
    } catch { $onlineOk = $false } 
  } 
 
  # 5) 无配置/失败：本地超 14 天则清除，避免 IP 失效 
  if (-not $onlineOk) { 
    if (-not $hasBlock) { return } 
    $localTs = Get-Ts $raw 
    if ($localTs -and ((New-TimeSpan $localTs (Get-Date)).TotalDays -gt $MaxAgeDays)) { Write-Hosts (Remove-Block $raw) } 
    return 
  } 
 
  # 6) 有配置：按时间戳判断是否更新，更新后刷新 DNS 
  $localTs = Get-Ts $raw 
  if ($hasBlock -and $localTs -and $onlineTs -and $onlineTs -le $localTs) { return } 
  $tsLine = if ($onlineTs) { $onlineTs.ToString('yyyy-MM-dd HH:mm:ss') } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } 
  $block  = "$BeginMark`r`n# GENERATED_TIME: $tsLine`r`n$($onlineText.Trim())`r`n$EndMark" 
  $baseTxt= if ($hasBlock) { Remove-Block $raw } else { $raw } 
  Write-Hosts (($baseTxt.TrimEnd()) + "`r`n" + $block + "`r`n") 
} 
if ($Worker) { Invoke-Worker; return } 
 
# ========================================================= 
# 引导分支：安装 / 升级 / 卸载 
# ========================================================= 
function Test-Admin { 
  $id = [Security.Principal.WindowsIdentity]::GetCurrent() 
  (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) 
} 
if (-not (Test-Admin)) { 
  Write-Host '需要管理员权限，正在请求提权...' -ForegroundColor Yellow 
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"irm $SelfUrl | iex`"" 
  return 
} 
 
function Get-OnlineVersion { 
  try { $t = (Invoke-WebRequest -UseBasicParsing $SelfUrl).Content 
    if ($t -match "\`$ScriptVersion\s*=\s*'([^']+)'") { $Matches[1] } } catch { $null } 
} 
function Get-LocalVersion { 
  if (Test-Path $SelfPath) { $t = Get-Content $SelfPath -Raw 
    if ($t -match "\`$ScriptVersion\s*=\s*'([^']+)'") { $Matches[1] } } else { $null } 
} 
function Test-Installed { [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) } 
function Test-Newer { param($o,$l) try { [version]$o -gt [version]$l } catch { $o -and $o -ne $l } } 
 
function Install-App { 
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null 
  Invoke-WebRequest -UseBasicParsing $SelfUrl -OutFile $SelfPath 
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' ` 
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfPath`" -Worker" 
  $t1 = New-ScheduledTaskTrigger -Daily -At $RunTime 
  $t2 = New-ScheduledTaskTrigger -AtStartup 
  $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest 
  $se = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew 
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $t1,$t2 -Principal $pr -Settings $se -Force | Out-Null 
  Write-Host "安装完成：每天 $RunTime 以 SYSTEM 静默运行（版本 $ScriptVersion）。" -ForegroundColor Green 
} 
function Uninstall-App { 
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue 
  if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force } 
  Write-Host '已卸载。' -ForegroundColor Green 
} 
function Read-One { $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } 
 
# ===== 主流程 ===== 
if (-not (Test-Installed)) { 
  Write-Host "未检测到 $AppName 服务。按 [回车] 开始安装，其它任意键退出。" 
  if ((Read-One).VirtualKeyCode -eq 13) { Install-App } else { return } 
} 
else { 
  $lv = Get-LocalVersion; $ov = Get-OnlineVersion 
  Write-Host "$AppName 已安装。本地版本：$lv  在线版本：$ov" 
  if (Test-Newer $ov $lv) { Write-Host '发现新版本。按 [1] 覆盖升级，[2] 卸载，其它任意键退出。' } 
  else                { Write-Host '当前已是最新。按 [2] 卸载，其它任意键退出。' } 
  switch ((Read-One).Character) { 
    '1' { if (Test-Newer $ov $lv) { Install-App } } 
    '2' { Uninstall-App } 
    default { return } 
  } 
} 
