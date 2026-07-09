#Requires -Version 5.1 
# GlobalNetSpeedConfigs 单文件脚本 gnsc.ps1 
# 无参数 = 安装/升级/卸载引导；-Worker = 计划任务每日执行 
param([switch]$Worker) 
 
# ===== 全局配置 ===== 
$ScriptVersion = '1.0.6' 
$AppName    = 'GlobalNetSpeedConfigs' 
# 多镜像，按顺序尝试，第一个成功即用（gh-proxy 通常最快） 
$Mirrors = @( 
  'https://gh-proxy.com/https://raw.githubusercontent.com/26eg/GlobalNetSpeedConfigs/main', 
  'https://cdn.jsdelivr.net/gh/26eg/GlobalNetSpeedConfigs@main', 
  'https://gnsc.aioz.cc', 
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
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)   # hosts 用无 BOM，避免中文注释乱码 
$Utf8Bom    = New-Object System.Text.UTF8Encoding($true)    # 脚本文件用带 BOM，避免 PS 5.1 按 GBK 误读脚本导致乱码/语法报错 
# 强制 TLS 1.2/1.3：PS 5.1 默认只启用 TLS1.0，对 Cloudflare/jsDelivr 等会握手失败并表现为"操作超时" 
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288 } catch { [Net.ServicePointManager]::SecurityProtocol = 3072 } 
[Net.ServicePointManager]::Expect100Continue = $false 
# 浏览器 UA：gh-proxy 等会对默认的 PowerShell UA 判定为爬虫并返回 429，用真实浏览器 UA 规避 
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36' 
$ProxyUrl = ''   # 如需经代理访问，填 'http://127.0.0.1:7890' 之类；注意 SYSTEM 计划任务不会继承用户的系统代理 
 
function Write-Log { param($m) try { Add-Content $LogPath ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m) -Encoding UTF8 } catch {} } 
function Pause-Exit { Write-Host ''; Write-Host '按回车键关闭本窗口...' -ForegroundColor DarkGray; [void][Console]::ReadLine(); exit } 
# 下载：带浏览器 UA + TLS1.2 + 30s 超时 + 每个镜像重试 2 次；记录 HTTP 状态码，遇 429 稍等再试 
function Get-Remote { param($rel) 
  foreach ($b in $Mirrors) { 
    $url = "$b/$rel" 
    for ($try=1; $try -le 2; $try++) { 
      try { 
        $p = @{ Uri=$url; UseBasicParsing=$true; UserAgent=$UA; TimeoutSec=30; Headers=@{ 'Cache-Control'='no-cache' } } 
        if ($ProxyUrl) { $p.Proxy = $ProxyUrl } 
        $r = Invoke-WebRequest @p 
        if ($r.StatusCode -eq 200 -and $r.Content) { return $r.Content } 
      } catch { 
        $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {} 
        Write-Log ("镜像失败 {0}（第{1}次 HTTP {2}）: {3}" -f $url,$try,$code,$_.Exception.Message) 
        if ($code -eq 429) { Start-Sleep -Seconds 3 }   # 被限流则稍等重试 
      } 
    } 
  } 
  return $null 
} 
# 首次修改前备份原始 hosts（带时间戳 .bak，同时在安装目录留一份） 
function Backup-Hosts { param($content) 
  try { 
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss' 
    $bak = "$HostsPath.$stamp.bak" 
    if ($content) { [System.IO.File]::WriteAllText($bak, $content, $Utf8NoBom) } 
    elseif (Test-Path $HostsPath) { Copy-Item $HostsPath $bak -Force } 
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null 
    Copy-Item $bak (Join-Path $InstallDir "hosts.$stamp.bak") -Force -ErrorAction SilentlyContinue 
    Write-Log "首次修改前已备份原始 hosts -> $bak" 
  } catch { Write-Log ('备份 hosts 失败：' + $_.Exception.Message) } 
} 
# 安全写入 hosts：先写临时文件，再原子替换；被占用则重试；失败绝不清空原文件（杜绝 0KB） 
function Set-HostsContent { param($text) 
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null 
  $tmp  = Join-Path $InstallDir 'hosts.new.tmp' 
  $rbak = Join-Path $InstallDir 'hosts.replace.bak'   # Replace 需真实备份路径，切勿传 $null 
  [System.IO.File]::WriteAllText($tmp, $text, $Utf8NoBom) 
  for ($i=1; $i -le 6; $i++) { 
    try { 
      if (Test-Path $HostsPath) { 
        try { (Get-Item $HostsPath -Force).Attributes = 'Normal' } catch {}   # 清只读/系统/隐藏，避免替换失败 
        [System.IO.File]::Replace($tmp, $HostsPath, $rbak)                    # 原子替换（第三参传真实路径，规避"路径的形式不合法"） 
      } 
      else { [System.IO.File]::Move($tmp, $HostsPath) } 
      ipconfig /flushdns | Out-Null 
      return $true 
    } catch { 
      Write-Log ("写 hosts 第 {0}/6 次失败：[{1}] {2}" -f $i,$_.Exception.GetType().Name,$_.Exception.Message) 
      Start-Sleep -Milliseconds 800 
    } 
  } 
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue 
  Write-Log 'hosts 写入最终失败，已保持原文件不变' 
  return $false 
} 
 
# ===== Worker 分支：计划任务每天以 SYSTEM 调用，绝不能有交互/暂停 ===== 
function Invoke-Worker { 
  Write-Log '=== worker 开始 ===' 
  try {   # 可选：脚本自更新（原子写自身，带 BOM） 
    $online = Get-Remote 'gnsc.ps1' 
    if ($online -and $online -match "\`$ScriptVersion\s*=\s*'([^']+)'" -and [version]$Matches[1] -gt [version]$ScriptVersion) { 
      [System.IO.File]::WriteAllText($SelfPath, $online, $Utf8Bom); Write-Log ('自更新到 ' + $Matches[1]) 
    } 
  } catch {} 
  $ipv4 = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } | 
    Sort-Object SkipAsSource | Select-Object -First 1).IPAddress 
  if (-not $ipv4) { Write-Log '无本地 IPv4，跳过'; return } 
  # 用【公网出口 IP】判定地区/ISP 
  $geo = $null 
  try { $geo = Invoke-RestMethod 'https://ipinfo.io/json' -UserAgent $UA -TimeoutSec 30 } catch { Write-Log ('ipinfo 失败: ' + $_.Exception.Message) } 
  if (-not $geo -or -not $geo.country) { Write-Log '无法获取公网地理信息，跳过本次'; return } 
  $rc  = if     ($geo.region -match 'Henan') { 'HN' } 
       elseif ($geo.region) { (($geo.region -replace '\W','') + 'XX').Substring(0,2).ToUpper() } 
       else { 'XX' } 
  $isp = if     ($geo.org -match 'UNICOM')  { 'CU' } 
       elseif ($geo.org -match 'TELECOM') { 'CT' } 
       elseif ($geo.org -match 'MOBILE')  { 'CM' } 
       else { 'XX' } 
  $cfgName = "hosts_$($geo.country)_${rc}_${isp}_${Business}.txt" 
  Write-Log ("公网IP={0} region={1} org={2} => {3}" -f $geo.ip,$geo.region,$geo.org,$cfgName) 
  $raw = Get-Content $HostsPath -Raw -ErrorAction SilentlyContinue 
  if ($null -eq $raw) { $raw = '' } 
  $hasBlock = $raw -match [regex]::Escape($BeginMark) 
  function Get-Ts { param($t) if ($t -match "$([regex]::Escape($BeginMark))\s*\r?\n# GENERATED_TIME:\s*(.+)") { try { [datetime]::Parse($Matches[1].Trim()) } catch { $null } } else { $null } } 
  function Remove-Block { param($t) [regex]::Replace($t, "(?s)\r?\n?$([regex]::Escape($BeginMark)).*?$([regex]::Escape($EndMark))\r?\n?", '') } 
  $onlineText = Get-Remote $cfgName 
  $onlineTs = $null 
  if ($onlineText -and $onlineText -match '# GENERATED_TIME:\s*(.+)') { try { $onlineTs = [datetime]::Parse($Matches[1].Trim()) } catch {} } 
  if (-not $onlineText) { 
    Write-Log ("未取到在线配置 {0}" -f $cfgName) 
    if (-not $hasBlock) { Write-Log '本地无自定义块，结束'; return } 
    $localTs = Get-Ts $raw 
    if ($localTs -and ((New-TimeSpan $localTs (Get-Date)).TotalDays -gt $MaxAgeDays)) { Set-HostsContent (Remove-Block $raw); Write-Log '本地超 14 天，已清除' } 
    return 
  } 
  $localTs = Get-Ts $raw 
  if ($hasBlock -and $localTs -and $onlineTs -and $onlineTs -le $localTs) { Write-Log '已最新，无需更新'; return } 
  if (-not $hasBlock) { Backup-Hosts $raw }   # 首次修改前自动备份 
  $tsLine = if ($onlineTs) { $onlineTs.ToString('yyyy-MM-dd HH:mm:ss') } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } 
  $block  = "$BeginMark`r`n# GENERATED_TIME: $tsLine`r`n$($onlineText.Trim())`r`n$EndMark" 
  $baseTxt= if ($hasBlock) { Remove-Block $raw } else { $raw } 
  if (Set-HostsContent (($baseTxt.TrimEnd()) + "`r`n" + $block + "`r`n")) { Write-Log ("已更新 hosts（{0}）并刷新 DNS" -f $cfgName) } 
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
    [System.IO.File]::WriteAllText($SelfPath, $self, $Utf8Bom)   # 脚本落盘带 BOM，避免 PS 5.1 按 GBK 误读 
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
    $raw = Get-Content $HostsPath -Raw -ErrorAction SilentlyContinue 
    if ($raw -match [regex]::Escape($BeginMark)) { 
      $clean = [regex]::Replace($raw, "(?s)\r?\n?$([regex]::Escape($BeginMark)).*?$([regex]::Escape($EndMark))\r?\n?", '') 
      Set-HostsContent $clean 
    } 
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force } 
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