#Requires -Version 5.1

# GlobalNetSpeedConfigs 单文件脚本 gnsc.ps1
# 无参数 = 安装/升级/卸载引导；-Worker = 计划任务每日执行
param([switch]$Worker)

# ===== 全局配置 =====
$ScriptVersion = '1.0.8'
$AppName    = 'GlobalNetSpeedConfigs'
# 多镜像，按顺序尝试，第一个成功即用（GitLab 国内可直连、缓存短，优先；GitHub 兜底）
$Mirrors = @(
  'https://gitlab.com/26eg/GlobalNetSpeedConfigs/-/raw/main',
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
# 强制 TLS 1.2/1.3：PS 5.1 默认只启用 TLS1.0，对 GitLab/GitHub 等会握手失败并表现为"操作超时"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 -bor 12288 } catch { [Net.ServicePointManager]::SecurityProtocol = 3072 }
[Net.ServicePointManager]::Expect100Continue = $false
# 浏览器 UA：部分公共镜像/代理会对默认的 PowerShell UA 判定为爬虫并返回 429，用真实浏览器 UA 规避
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36'
$ProxyUrl = ''   # 如需经代理访问，填 'http://127.0.0.1:7890' 之类；注意 SYSTEM 计划任务不会继承用户的系统代理
# STUN 服务器：国内在前——旁路由/透明代理对国内流量默认直连，UDP 探测到的才是真实出口 IP；境外仅兜底
$StunServers = @(
  'stun.miwifi.com:3478',
  'stun.chat.bilibili.com:3478',
  'stun.l.google.com:19302',
  'stun.cloudflare.com:3478'
)
# 数据中心/云厂商关键词：ipinfo 的 org 命中即疑似代理出口，仅告警便于排查
$DcOrgPattern = 'Amazon|Google|Cloudflare|Microsoft|Azure|DigitalOcean|Linode|Akamai|OVH|Hetzner|Vultr|Oracle|Fastly|Alibaba|Tencent|Leaseweb|Choopa'
# 中文省份 -> 英文名（与 ipinfo.io 的 region 命名一致），保证国内源与 ipinfo 两条路径生成的地区码完全相同
$CnProvinceMap = @{
  '北京'='Beijing';   '天津'='Tianjin';  '河北'='Hebei';     '山西'='Shanxi';   '内蒙古'='Inner Mongolia';
  '辽宁'='Liaoning';  '吉林'='Jilin';    '黑龙江'='Heilongjiang'; '上海'='Shanghai'; '江苏'='Jiangsu';
  '浙江'='Zhejiang';  '安徽'='Anhui';    '福建'='Fujian';    '江西'='Jiangxi';  '山东'='Shandong';
  '河南'='Henan';     '湖北'='Hubei';    '湖南'='Hunan';     '广东'='Guangdong';'广西'='Guangxi';
  '海南'='Hainan';    '重庆'='Chongqing';'四川'='Sichuan';   '贵州'='Guizhou';  '云南'='Yunnan';
  '西藏'='Tibet';     '陕西'='Shaanxi';  '甘肃'='Gansu';     '青海'='Qinghai';  '宁夏'='Ningxia';
  '新疆'='Xinjiang'
}

function Write-Log { param($m) try { Add-Content $LogPath ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$m) -Encoding UTF8 } catch {} }
function Pause-Exit { Write-Host ''; Write-Host '按回车键关闭本窗口...' -ForegroundColor DarkGray; [void][Console]::ReadLine(); exit }
# 日志轮转：超过 512KB 只保留最近 300 行，防止无限增长
function Limit-Log {
  try {
    if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 512KB)) {
      $tail = Get-Content $LogPath -Tail 300 -Encoding UTF8
      Set-Content $LogPath $tail -Encoding UTF8
      Write-Log '[日志超 512KB 已轮转，保留最近 300 行]'
    }
  } catch {}
}
# 下载：带浏览器 UA + TLS1.2 + 30s 超时 + 每个镜像重试 2 次；404 说明文件不存在，不重试直接换下一镜像
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
        if ($code -eq 404) { break }                    # 文件不存在不是瞬态错误，直接换下一个镜像
        if ($code -eq 429) { Start-Sleep -Seconds 3 }   # 被限流则稍等重试
      }
    }
  }
  return $null
}
# 拉取文本：统一 UA / 超时 / $ProxyUrl；按 UTF-8 强制解码，规避 PS 5.1 缺 charset 时按 ISO-8859-1 误读中文
function Get-Http { param($url,[int]$TimeoutSec=10)
  try {
    $p = @{ Uri=$url; UseBasicParsing=$true; UserAgent=$UA; TimeoutSec=$TimeoutSec; Headers=@{ 'Accept'='application/json' } }
    if ($ProxyUrl) { $p.Proxy = $ProxyUrl }
    $r = Invoke-WebRequest @p
    if ($r.StatusCode -eq 200 -and $r.RawContentStream) {
      return [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    }
  } catch { Write-Log ("geo 接口失败 {0}: {1}" -f $url,$_.Exception.Message) }
  return $null
}
function Get-Json { param($url,[int]$TimeoutSec=10)
  $t = Get-Http $url $TimeoutSec
  if ($t) { try { return ($t | ConvertFrom-Json) } catch { Write-Log ("geo 接口返回非 JSON {0}" -f $url) } }
  return $null
}

# ===== 出口 IP / 地理位置检测 =====
# STUN Binding（RFC 5389）：即 WebRTC 探测公网 IP 的底层协议，用 UdpClient 内嵌实现，零依赖。
# 依次询问 $StunServers，返回公网映射 IPv4；国内 STUN 走直连路由，旁路由环境下拿到的是真实出口。
function Get-StunIP {
  foreach ($s in $StunServers) {
    $udp = $null
    try {
      $h,$port = $s -split ':'
      $udp = New-Object System.Net.Sockets.UdpClient
      $udp.Client.ReceiveTimeout = 3000
      $udp.Client.SendTimeout    = 3000
      $udp.Connect($h, [int]$port)
      # 请求：类型 0x0001(Binding) + 长度 0 + Magic Cookie 0x2112A442 + 12 字节随机事务 ID
      $req = New-Object byte[] 20
      $req[1] = 0x01; $req[4] = 0x21; $req[5] = 0x12; $req[6] = 0xA4; $req[7] = 0x42
      $tid = New-Object byte[] 12
      (New-Object System.Random).NextBytes($tid)
      [Array]::Copy($tid, 0, $req, 8, 12)
      [void]$udp.Send($req, $req.Length)
      $ep   = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
      $resp = $udp.Receive([ref]$ep)
      # 校验：Binding Success(0x0101) 且事务 ID 一致
      if ($resp.Length -lt 20 -or $resp[0] -ne 0x01 -or $resp[1] -ne 0x01) { continue }
      $tidOk = $true; for ($i=0; $i -lt 12; $i++) { if ($resp[8+$i] -ne $tid[$i]) { $tidOk = $false; break } }
      if (-not $tidOk) { continue }
      # 遍历属性：优先 XOR-MAPPED-ADDRESS(0x0020，需与 Magic Cookie 异或)，兼容旧式 MAPPED-ADDRESS(0x0001)
      $pos = 20
      while ($pos + 4 -le $resp.Length) {
        $atype = 256 * $resp[$pos] + $resp[$pos+1]
        $alen  = 256 * $resp[$pos+2] + $resp[$pos+3]
        $v = $pos + 4
        if ($v + $alen -gt $resp.Length) { break }
        if (($atype -eq 0x0020 -or $atype -eq 0x8020) -and $alen -ge 8 -and $resp[$v+1] -eq 0x01) {
          $ip = ('{0}.{1}.{2}.{3}' -f ($resp[$v+4] -bxor 0x21),($resp[$v+5] -bxor 0x12),($resp[$v+6] -bxor 0xA4),($resp[$v+7] -bxor 0x42))
          Write-Log ("STUN({0}) 探测到出口 IP: {1}" -f $s,$ip)
          return $ip
        }
        if ($atype -eq 0x0001 -and $alen -ge 8 -and $resp[$v+1] -eq 0x01) {
          $ip = ('{0}.{1}.{2}.{3}' -f $resp[$v+4],$resp[$v+5],$resp[$v+6],$resp[$v+7])
          Write-Log ("STUN({0}) 探测到出口 IP: {1}" -f $s,$ip)
          return $ip
        }
        $pos = $v + $alen + ((4 - ($alen % 4)) % 4)   # 属性按 4 字节对齐
      }
    } catch {} finally { if ($udp) { $udp.Close() } }
  }
  Write-Log 'STUN 全部服务器探测失败'
  return $null
}
# 运营商归一化：中英文关键词皆识别
function Get-IspCode { param($s)
  if     ($s -match '联通|UNICOM')           { return 'CU' }
  elseif ($s -match '电信|TELECOM|CHINANET') { return 'CT' }
  elseif ($s -match '移动|铁通|MOBILE|CMCC') { return 'CM' }
  return 'XX'
}
# 国内接口（中文结果）-> 归一化 geo 对象；regionEn 与 ipinfo 命名对齐，保证地区码一致
function ConvertFrom-CnGeo { param($ip,$country,$prov,$isp,$src)
  $regionEn = ''
  foreach ($k in $CnProvinceMap.Keys) { if ($prov -and $prov -like "$k*") { $regionEn = $CnProvinceMap[$k]; break } }
  [pscustomobject]@{ ip=$ip; isCN=($country -eq '中国'); country=$country; regionEn=$regionEn; ispCode=(Get-IspCode "$isp"); src=$src }
}
# ipinfo（英文结果）-> 归一化 geo 对象；org 命中云厂商关键词时告警（疑似代理/旁路由出口）
function ConvertFrom-IpInfo { param($j,$src)
  if ($j.org -match $DcOrgPattern) { Write-Log ("警告：出口 org={0} 疑似代理/旁路由节点，检测结果可能不可信" -f $j.org) }
  [pscustomobject]@{ ip=$j.ip; isCN=($j.country -eq 'CN'); country=$j.country; regionEn="$($j.region)"; ispCode=(Get-IspCode "$($j.org)"); src=$src }
}
# 指定 IP 反查归属地（用于 STUN 拿到的真实出口 IP）：反查结果与请求走什么路由无关
function Get-GeoForIP { param($ip)
  $j = Get-Json ("https://qifu-api.baidubce.com/ip/geo/v1/district?ip={0}" -f $ip)
  if ($j -and $j.code -eq 'Success' -and $j.data) { return ConvertFrom-CnGeo $ip $j.data.country $j.data.prov $j.data.isp 'STUN+百度' }
  $j = Get-Json ("http://ip-api.com/json/{0}?lang=zh-CN&fields=status,country,regionName,isp" -f $ip)
  if ($j -and $j.status -eq 'success') { return ConvertFrom-CnGeo $ip $j.country $j.regionName $j.isp 'STUN+ip-api' }
  $j = Get-Json ("https://ipinfo.io/{0}/json" -f $ip) 20
  if ($j -and $j.country) { return ConvertFrom-IpInfo $j 'STUN+ipinfo' }
  return $null
}
# 出口检测总入口，按可信度分层：
#  1) STUN（国内服务器优先）拿真实出口 IP 再反查归属地——旁路由环境唯一可靠的手段；
#  2) STUN 显示境外或失败时，用国内直连 HTTP 源复核/兜底（旁路由对其直连，返回的也是真实出口）；
#  3) 国内源全失败才回落 ipinfo.io（走代理时它看到的是代理出口，仅作最后兜底并告警）。
function Get-ExitGeo {
  $stunGeo = $null
  $stunIp = Get-StunIP
  if ($stunIp) {
    $stunGeo = Get-GeoForIP $stunIp
    if ($stunGeo -and $stunGeo.isCN) { return $stunGeo }
    if ($stunGeo) { Write-Log ("STUN 出口显示为境外（{0}），用国内直连源复核..." -f $stunGeo.country) }
  }
  $j = Get-Json 'https://api.bilibili.com/x/web-interface/zone'
  if ($j -and $j.data -and $j.data.addr) { return ConvertFrom-CnGeo $j.data.addr $j.data.country $j.data.province $j.data.isp 'bilibili' }
  $j = Get-Json 'https://qifu-api.baidubce.com/ip/local/geo/v1/district'
  if ($j -and $j.code -eq 'Success' -and $j.data) { return ConvertFrom-CnGeo $j.ip $j.data.country $j.data.prov $j.data.isp '百度' }
  $t = Get-Http 'https://myip.ipip.net'
  if ($t -and $t -match '当前 IP：\s*(\d{1,3}(?:\.\d{1,3}){3})\s*来自于：\s*(.+)') {
    $ipipIp = $Matches[1]; $parts = @($Matches[2].Trim() -split '\s+')
    if ($parts.Count -ge 2) { return ConvertFrom-CnGeo $ipipIp $parts[0] $parts[1] $parts[-1] 'ipip.net' }
  }
  if ($stunGeo) { return $stunGeo }   # 国内 HTTP 源全失败，采信 STUN 的境外结论
  $j = Get-Json 'https://ipinfo.io/json' 30
  if ($j -and $j.country) { return ConvertFrom-IpInfo $j 'ipinfo' }
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
  Limit-Log
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
  $raw = Get-Content $HostsPath -Raw -ErrorAction SilentlyContinue
  if ($null -eq $raw) { $raw = '' }
  $hasBlock = $raw -match [regex]::Escape($BeginMark)
  function Get-Ts { param($t) if ($t -match "$([regex]::Escape($BeginMark))\s*\r?\n# GENERATED_TIME:\s*(.+)") { try { [datetime]::Parse($Matches[1].Trim()) } catch { $null } } else { $null } }
  function Remove-Block { param($t) [regex]::Replace($t, "(?s)\r?\n?$([regex]::Escape($BeginMark)).*?$([regex]::Escape($EndMark))\r?\n?", '') }
  # 分层检测【真实出口】：STUN -> 国内直连源 -> ipinfo（旁路由环境下 ipinfo 看到的是代理出口，不能直接采信）
  $geo = Get-ExitGeo
  if (-not $geo) { Write-Log '所有出口 IP 检测源均失败，跳过本次'; return }
  Write-Log ("出口IP={0} 国家={1} 地区={2} ISP={3}（来源 {4}）" -f $geo.ip,$geo.country,$geo.regionEn,$geo.ispCode,$geo.src)
  if (-not $geo.isCN) {   # 出口在中国以外：不存在需要加速的场景，清掉本脚本写入的配置
    if ($hasBlock) {
      if (Set-HostsContent (Remove-Block $raw)) { Write-Log '出口位于中国以外，已清除本脚本写入的 hosts 配置并刷新 DNS' }
    } else { Write-Log '出口位于中国以外且本地无自定义块，结束' }
    return
  }
  $rc  = if     ($geo.regionEn -match 'Henan') { 'HN' }
       elseif ($geo.regionEn) { (($geo.regionEn -replace '\W','') + 'XX').Substring(0,2).ToUpper() }
       else { 'XX' }
  $cfgName = "hosts_CN_${rc}_$($geo.ispCode)_${Business}.txt"
  Write-Log ("匹配配置文件 => {0}" -f $cfgName)
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
  # 剥离在线配置自带的 GENERATED_TIME 行，只保留下面统一写入的一行，避免块内出现两行时间戳
  $body   = ($onlineText -replace '(?m)^\s*#\s*GENERATED_TIME:.*(\r?\n|$)', '').Trim()
  $block  = "$BeginMark`r`n# GENERATED_TIME: $tsLine`r`n$body`r`n$EndMark"
  $baseTxt= if ($hasBlock) { Remove-Block $raw } else { $raw }
  if (Set-HostsContent (($baseTxt.TrimEnd()) + "`r`n" + $block + "`r`n")) { Write-Log ("已更新 hosts（{0}）并刷新 DNS" -f $cfgName) }
}
if ($Worker) { Invoke-Worker; return }

# ===== 引导分支：安装 / 升级 / 卸载（交互式，结尾统一暂停）=====
function Test-Admin { $id=[Security.Principal.WindowsIdentity]::GetCurrent(); (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }
if (-not (Test-Admin)) {
  Write-Host '需要管理员权限，正在弹出 UAC 提权窗口，请在弹窗中点 [是]...' -ForegroundColor Yellow
  if ($PSCommandPath) {   # 本地已有脚本文件：直接以文件方式提权重启，不依赖网络
    Start-Process powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
  } else {                # irm|iex 方式运行：按镜像顺序在线拉取，避免单点依赖
    $chain = 'try { irm ' + $Mirrors[0] + '/gnsc.ps1 | iex } catch { irm ' + $Mirrors[1] + '/gnsc.ps1 | iex }'
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$chain`""
  }
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
