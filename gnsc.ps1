#Requires -Version 5.1 
# GlobalNetSpeedConfigs 单文件脚本 gnsc.ps1 
# 无参数 = 安装/升级/卸载引导；-Worker = 计划任务每日执行 
param([switch]$Worker) 
 
# ===== 全局配置 ===== 
$ScriptVersion = '1.0.1' 
$AppName    = 'GlobalNetSpeedConfigs' 
$Base       = 'https://gnsc.aioz.cc'          # 你的 Cloudflare 加速域名 
$SelfUrl    = "$Base/gnsc.ps1" 
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
 
# ===== Worker 分支：计划任务每天以 SYSTEM 调用，绝不能有交互/暂停 ===== 
function Invoke-Worker { 
  Write-Log '=== worker 开始 ===' 
  try {   # 可选：脚本自更新 
    $online = (Invoke-WebRequest -UseBasicParsing $SelfUrl -TimeoutSec 20).Content 
    if ($online -match "\`$ScriptVersion\s*=\s*'([^']+)'" -and [version]$Matches[1] -gt [version]$ScriptVersion) { 
      Set-Content $SelfPath $online -Encoding UTF8; Write-Log ('自更新到 ' + $Matches[1]) 
    } 
  } catch {} 
  $ipv4 = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | 
    Sort-Object SkipAsSource | Select-Object -First 1).IPAddress 
  if (-not $ipv4) { Write-Log '无 IPv4，跳过'; return } 
  $cfgName = $null 
  try { 
    $info = Invoke-RestMethod "https://ipinfo.io/$ipv4/json" -TimeoutSec 15 
    $rc  = if ($info.region -match 'Henan') { 'HN' } else { ($info.region -replace '\W','').Substring(0,2).ToUpper() } 
    $isp = if     ($info.org -match 'UNICOM')  { 'CU' } 
           elseif ($info.org -match 'TELECOM') { 'CT' } 
           elseif ($info.org -match 'MOBILE')  { 'CM' } 
           else { 'XX' } 
    $cfgName = "hosts_$($info.country)_${rc}_${isp}_${Business}.txt" 
  } catch { $cfgName = $null } 
  $raw = Get-Content $HostsPath -Raw -ErrorAction SilentlyContinue 
  $hasBlock = $raw -match [regex]::Escape($BeginMark) 
  function Get-Ts { param($t) if ($t -match "$([regex]::Escape($BeginMark))\s*\r?\n# GENERATED_TIME:\s*(.+)") { try { [datetime]::Parse($Matches[1].Trim()) } catch { $null } } else { $null } } 
  function Remove-Block { param($t) [regex]::Replace($t, "(?s)\r?\n?$([regex]::Escape($BeginMark)).*?$([regex]::Escape($EndMark))\r?\n?", '') } 
  function Write-Hosts { param($t) Set-Content -Path $HostsPath -Value $t -Encoding ASCII; ipconfig /flushdns | Out-Null } 
  $onlineText=$null; $onlineTs=$null; $onlineOk=$false 
  if ($cfgName) { 
    try { 
      $onlineText = (Invoke-WebRequest -UseBasicParsing "$Base/$cfgName" -TimeoutSec 20).Content 
      if ($onlineText -match '# GENERATED_TIME:\s*(.+)') { $onlineTs = [datetime]::Parse($Matches[1].Trim()) } 
      $onlineOk = $true 
    } catch { $onlineOk = $false } 
  } 
  if (-not $onlineOk) { 
    if (-not $hasBlock) { Write-Log '无在线配置且本地无自定义块，结束'; return } 
    $localTs = Get-Ts $raw 
    if ($localTs -and ((New-TimeSpan $localTs (Get-Date)).TotalDays -gt $MaxAgeDays)) { Write-Hosts (Remove-Block $raw); Write-Log '本地超 14 天，已清除' } 
    return 
  } 
  $localTs = Get-Ts $raw 
  if ($hasBlock -and $localTs -and $onlineTs -and $onlineTs -le $localTs) { Write-Log '已最新，无需更新'; return } 
  $tsLine = if ($onlineTs) { $onlineTs.ToString('yyyy-MM-dd HH:mm:ss') } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } 
  $block  = "$BeginMark`r`n# GENERATED_TIME: $tsLine`r`n$($onlineText.Trim())`r`n$EndMark" 
  $baseTxt= if ($hasBlock) { Remove-Block $raw } else { $raw } 
  Write-Hosts (($baseTxt.TrimEnd()) + "`r`n" + $block + "`r`n") 
  Write-Log '已更新 hosts 并刷新 DNS' 
} 
if ($Worker) { Invoke-Worker; return } 
 
# ===== 引导分支：安装 / 升级 / 卸载（交互式，结尾统一暂停）===== 
function Test-Admin { $id=[Security.Principal.WindowsIdentity]::GetCurrent(); (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) } 
if (-not (Test-Admin)) { 
  Write-Host '需要管理员权限，正在弹出 UAC 提权窗口，请在弹窗中点 [是]...' -ForegroundColor Yellow 
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"irm $SelfUrl | iex`"" 
  return 
} 
function Get-OnlineVersion { try { $t=(Invoke-WebRequest -UseBasicParsing $SelfUrl -TimeoutSec 20).Content; if ($t -match "\`$ScriptVersion\s*=\s*'([^']+)'") { $Matches[1] } } catch { $null } } 
function Get-LocalVersion { if (Test-Path $SelfPath) { $t=Get-Content $SelfPath -Raw; if ($t -match "\`$ScriptVersion\s*=\s*'([^']+)'") { $Matches[1] } } else { $null } } 
function Test-Installed { [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) } 
function Test-Newer { param($o,$l) try { [version]$o -gt [version]$l } catch { $o -and $o -ne $l } } 
function Read-One { 
  try { return $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } 
  catch { $s = Read-Host '请输入选项后回车'; $c = if ($s.Length) { $s[0] } else { [char]13 }; return [pscustomobject]@{ Character=$c; VirtualKeyCode=[int]$c } } 
} 
 
function Install-App { 
  param([switch]$RunNow) 
  try { 
    Write-Host '-> 创建安装目录...' 
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null 
    Write-Host '-> 下载最新脚本...' 
    Invoke-WebRequest -UseBasicParsing $SelfUrl -OutFile $SelfPath -TimeoutSec 30 
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
      Write-Host '[OK] 首次同步完成，可打开 hosts 查看结果。' -ForegroundColor Green 
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
  else                    { Write-Host '  [1] 重新安装 / 修复（覆盖安装）' } 
  Write-Host '  [2] 卸载        [其它键] 退出' 
  switch ((Read-One).Character) { 
    '1' { Install-App -RunNow } 
    '2' { Uninstall-App } 
    default { } 
  } 
} 
Pause-Exit
