#Requires -Version 5.1 
# GlobalNetSpeedConfigs 单文件脚本 gnsc.ps1 
# 无参数 = 安装/升级/卸载引导；-Worker = 计划任务每日执行 
param([switch]$Worker) 
 
# ===== 全局配置 ===== 
$ScriptVersion = '1.0.2' 
$AppName    = 'GlobalNetSpeedConfigs' 
# 多镜像，按顺序尝试，第一个成功即用（gh-proxy 通常最快，可自行调整顺序） 
$Mirrors = @( 
  'https://gh-proxy.com/https://raw.githubusercontent.com/26eg/GlobalNetSpeedConfigs/main', 
  'https://gnsc.aioz.cc', 
  'https://cdn.jsdelivr.net/gh/26eg/GlobalNetSpeedConfigs@main', 
  'https://raw.githubusercontent.com/26eg/GlobalNetSpeedConfigs/main' 
) 
$InstallDir = Join-Path $env:ProgramData $AppName 
$SelfPath   = Join-Path $InstallDir 'gnsc.ps1' 
$LogPath    = Join-Path $InstallDir 'worker.log' 
$TaskName   = $AppName 
$RunTime    = '04:00' 
$HostsPath  = "$env:WINDIR\System32\drivers\etc\hosts" 
$Tag        = $AppName 
$BeginMark  = "# >>> $Tag BEGIN >>>" 
$EndMark    = "# <<< $Tag END <<<" 
$MaxAgeDays = 14 
$Business   = 'Amazon' 
 
function Write-Log { param($m) try { Add-Content $LogPath ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m) -Encoding UTF8 } catch {} } 
function Pause-Exit { Write-Host ''; Write-Host '按回车键关闭本窗口...' -ForegroundColor DarkGray; [void][Console]::ReadLine(); exit } 
# 多镜像取文本：任一镜像成功即返回内容，全部失败返回 $null 
function Get-Remote { param($rel) 
  foreach ($b in $Mirrors) { 
    try { return (Invoke-WebRequest -UseBasicParsing "$b/$rel" -TimeoutSec 15).Content } 
    catch { Write-Log ("镜像失败 {0}/{1} : {2}" -f $b,$rel,$_.Exception.Message) } 
  } 
  return $null 
} 
 
# ===== Worker 分支：计划任务每天以 SYSTEM 调用，绝不能有交互/暂停 ===== 
function Invoke-Worker { 
  Write-Log '=== worker 开始 ===' 
  try {   # 可选：脚本自更新 
    $online = Get-Remote 'gnsc.ps1' 
    if ($online -and $online -match "\`$ScriptVersion\s*=\s*'([^']+)'" -and [version]$Matches[1] -gt [version]$ScriptVersion) { 
      Set-Content $SelfPath $online -Encoding UTF8; Write-Log ('自更新到 ' + $Matches[1]) 
    } 
  } catch {} 
  # 1) 本地 IPv4 仅作连通性判断（内网地址，不能用于地理定位） 
  $ipv4 = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | 
    Sort-Object SkipAsSource | Select-Object -First 1).IPAddress 
  if (-not $ipv4) { Write-Log '无本地 IPv4，跳过'; return } 
  # 2) 用【公网出口 IP】判定地区/ISP —— 关键：不要把内网 IP 传给 ipinfo 
  $geo = $null 
  try { $geo = Invoke-RestMethod 'https://ipinfo.io/json' -TimeoutSec 15 } catch { Write-Log ('ipinfo 失败: ' + $_.Exception.Message) } 
  if (-not $geo -or -not $geo.country) { Write-Log '无法获取公网地理信息，跳过本次'; return } 
  $rc  = if     ($geo.region -match 'Henan')    { 'HN' } 
       elseif ($geo.region) { ($geo.region -replace '\W','' + 'XX').Substring(0,2).ToUpper() } else { 'XX' } 
  $isp = if     ($geo.org -match 'UNICOM')  { 'CU' } 
       elseif ($geo.org -match 'TELECOM') { 'CT' } 
       elseif ($geo.org -match 'MOBILE')  { 'CM' } 
       else { 'XX' } 
  $cfgName = "hosts_$($geo.country)_${rc}_${isp}_${Business}.txt" 
  Write-Log ("公网IP={0} region={1} org={2} => {3}" -f $geo.ip,$geo.region,$geo.org,$cfgName) 
  # 3) 工具函数 
  $raw = Get-Content $HostsPath -Raw -ErrorAction SilentlyContinue 
  $hasBlock = $raw -match [regex]::Escape($BeginMark) 
  function Get-Ts { param($t) if ($t -match "$([regex]::Escape($BeginMark))\s*\r?\n# GENERATED_TIME:\s*(.+)") { try { [datetime]::Parse($Matches[1].Trim()) } catch { $null } } else { $null } } 
  function Remove-Block { param($t) [regex]::Replace($t, "(?s)\r?\n?$([regex]::Escape($BeginMark)).*?$([regex]::Escape($EndMark))\r?\n?", '') } 
  function Write-Hosts { param($t) Set-Content -Path $HostsPath -Value $t -Encoding ASCII; ipconfig /flushdns | Out-Null } 
  # 4) 多镜像拉取在线配置 
  $onlineText = Get-Remote $cfgName 
  $onlineTs = $null 
  if ($onlineText -and $onlineText -match '# GENERATED_TIME:\s*(.+)') { try { $onlineTs = [datetime]::Parse($Matches[1].Trim()) } catch {} } 
  # 5) 无对应配置/全部镜像失败：本地超 14 天则清除，避免 IP 失效 
  if (-not $onlineText) { 
    Write-Log ("未取到在线配置 {0}" -f $cfgName) 
    if (-not $hasBlock) { Write-Log '本地无自定义块，结束'; return } 
    $localTs = Get-Ts $raw 
    if ($localTs -and ((New-TimeSpan $localTs (Get-Date)).TotalDays -gt $MaxAgeDays)) { Write-Hosts (Remove-Block $raw); Write-Log '本地超 14 天，已清除' } 
    return 
  } 
  # 6) 有配置：按时间戳判断是否更新，更新后刷新 DNS 
  $localTs = Get-Ts $raw 
  if ($hasBlock -and $localTs -and $onlineTs -and $onlineTs -le $localTs) { Write-Log '已最新，无需更新'; return } 
  $tsLine = if ($onlineTs) { $onlineTs.ToString('yyyy-MM-dd HH:mm:ss') } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } 
  $block  = "$BeginMark`r`n# GENERATED_TIME: $tsLine`r`n$($onlineText.Trim())`r`n$EndMark" 
  $baseTxt= if ($hasBlock) { Remove-Block $raw } else { $raw } 
  Write-Hosts (($baseTxt.TrimEnd()) + "`r`n" + $block + "`r`n") 
  Write-Log ("已更新 hosts（{0}）并刷新 DNS" -f $cfgName) 
} 
if ($Worker) { Invoke-Worker; return } 
 
# ===== 引导分支：安装 / 升级 / 卸载（交互式，结尾统一暂停）===== 
function Test-Admin { $id=[Security.Principal.WindowsIdentity]::GetCurrent(); (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) } 
if (-not (Test-Admin)) { 
  Write-Host '需要管理员权限，正在弹出 UAC 提权窗口，请在弹窗中点 [是]...' -ForegroundColor Yellow 
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"irm $($Mirrors[0])/gnsc.ps1 | iex`"" 
  return 
} 
function Get-OnlineVersion { $t = Get-Remote 'gnsc.ps1'; if ($t -and $t -match "\`$ScriptVersion\s*=\s*'([^']+)'") { $Matches[1] } } 
function Get-LocalVersion { if (Test-Path $SelfPath) { $t=Get-Content $SelfPath -Raw; if ($t -match "\`$ScriptVersion\s*=\s*'([^']+)'") { $Matches[1] } } else { $null } } 
function Test-Installed { [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) } 
function Test-Newer { param($o,$l) try { [version]$o -gt [version]$l } catch { $o -and $o -ne $l } } 
function Read-One { try { return $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { $s = Read-Host '请输入选项后回车'; $c = if ($s.Length) { $s[0] } else { [char]13 }; return [pscustomobject]@{ Character=$c; VirtualKeyCode=[int]$c } } } 
 
function Install-App { 
  param([switch]$RunNow) 
  try { 
    Write-Host '-> 创建安装目录...' 
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null 
    Write-Host '-> 下载最新脚本（多镜像自动择优）...' 
    $self = Get-Remote 'gnsc.ps1' 
    if (-not $self) { throw '所有镜像均无法下载 gnsc.ps1' } 
    Set-Content $SelfPath $self -Encoding UTF8 
    Write-Host ('-> 注册计划任务（SYSTEM，每天 {0}）...' -f $RunTime) 
    $psExe   = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' 
    $argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Worker' -f $SelfPath 
    $action  = New-ScheduledTaskAction -Execute $psExe -Argument $argLine 
    $t1 = New-ScheduledTaskTrigger -Daily -At $RunTime 
    $t2 = New-ScheduledTaskTrigger -AtStartup 
    $pr = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest 
    $se = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew 
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $t1,$t2 -Principal $pr -Settings $se -Force | Out-Null 
    Write-Host ('[OK] 安装完成（版本 {0}）。计划任务 [{1}] 已创建。' -f $ScriptVersion,$TaskName) -ForegroundColor Green 
    $a = (Get-ScheduledTask -TaskName $TaskName).Actions[0] 
    Write-Host ('  程序：{0}' -f $a.Execute)   -ForegroundColor DarkGray 
    Write-Host ('  参数：{0}' -f $a.Arguments) -ForegroundColor DarkGray 
    if ($RunNow) { 
      Write-Host '-> 立即执行一次，同步 hosts...' 
      Invoke-Worker 
      Write-Host ('[OK] 首次同步完成。详情见日志：{0}' -f $LogPath) -ForegroundColor Green 
    } 
  } catch { 
    Write-Host ('[X] 安装失败：{0}' -f $_.Exception.Message) -ForegroundColor Red 
  } 
} 
function Uninstall-App { 
  try { 
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue 
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force } 
    $raw = Get-Content $HostsPath -Raw -ErrorAction SilentlyContinue 
    if ($raw -match [regex]::Escape($BeginMark)) { 
      $clean = [regex]::Replace($raw, "(?s)\r?\n?$([regex]::Escape($BeginMark)).*?$([regex]::Escape($EndMark))\r?\n?", '') 
      Set-Content -Path $HostsPath -Value $clean -Encoding ASCII; ipconfig /flushdns | Out-Null 
    } 
    Write-Host '[OK] 已卸载并清理 hosts。' -ForegroundColor Green 
  } catch { Write-Host ('[X] 卸载失败：{0}' -f $_.Exception.Message) -ForegroundColor Red } 
} 
 
# ===== 主流程 ===== 
Write-Host ('==== {0}  安装向导  v{1} ====' -f $AppName,$ScriptVersion) -ForegroundColor Cyan 
if (-not (Test-Installed)) { 
  Write-Host '状态：未安装。   [回车] 立即安装    [其它键] 退出' 
  if ((Read-One).VirtualKeyCode -eq 13) { Install-App -RunNow } 
} 
else { 
  Write-Host '-> 正在检查版本...' 
  $lv = Get-LocalVersion; $ov = Get-OnlineVersion 
  Write-Host ('状态：已安装。本地 {0}  /  在线 {1}' -f $lv,$ov) 
  if (Test-Newer $ov $lv) { Write-Host '  [1] 升级到新版本（覆盖安装）' } 
  else                { Write-Host '  [1] 重新安装 / 修复（覆盖安装）' } 
  Write-Host '  [2] 卸载        [其它键] 退出' 
  switch ((Read-One).Character) { 
    '1' { Install-App -RunNow } 
    '2' { Uninstall-App } 
    default { } 
  } 
} 
Pause-Exit
