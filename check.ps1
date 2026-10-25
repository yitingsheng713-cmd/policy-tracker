# =====================================================================
#  check.ps1 — ESG/双碳/电力/碳市场 政策新增追踪
#
#  用法：
#    正常检查：  powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1
#    离线测试：  powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1 -TestLocal
#    调整回看：  powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1 -DaysBack 60
#
#  说明：从 sources.json 里每个来源的列表页抓取标题链接，按 keywords.txt
#        做子串匹配，对比 seen.json 去重后输出新增条目到 reports/ 并弹通知。
# =====================================================================
[CmdletBinding()]
param(
    [string]$Root = '',
    [int]$DaysBack = 45,
    [switch]$TestLocal
)

$ErrorActionPreference = 'Continue'

# ---------- 路径 ----------
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = $PSScriptRoot
}
$KeywordsFile = Join-Path $Root 'keywords.txt'
$SourcesFile  = Join-Path $Root 'sources.json'
$SeenFile     = Join-Path $Root 'seen.json'
$ReportsDir   = Join-Path $Root 'reports'
$LogFile      = Join-Path $Root 'log\run.log'

if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null }
if (-not (Test-Path (Split-Path $LogFile))) { New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null }

function Log([string]$msg) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

# ---------- 读取配置 ----------
$Keywords = @()
if (Test-Path $KeywordsFile) {
    $Keywords = @(Get-Content $KeywordsFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
$Sources = @()
if (Test-Path $SourcesFile) {
    $Sources = Get-Content $SourcesFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $Sources = @($Sources)
}
$Seen = @{}
if (Test-Path $SeenFile) {
    $arr = Get-Content $SeenFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $arr = @($arr)
    foreach ($it in $arr) { if ($it.url) { $Seen[$it.url] = $it } }
}

Log "== 开始检查：关键词 $($Keywords.Count) 个，来源 $($Sources.Count) 个，回看 $DaysBack 天 =="

# ---------- 工具函数 ----------
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'

function Decode-Html([byte[]]$bytes) {
    $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(4000, $bytes.Length))
    if ($head -match 'charset=["'']?(gb|gb2312|gbk|936)') {
        return [System.Text.Encoding]::GetEncoding('GB2312').GetString($bytes)
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-PageHtml([string]$url) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -UserAgent $UA -Headers @{
            'Accept'          = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
            'Accept-Language' = 'zh-CN,zh;q=0.9,en;q=0.8'
            'Referer'         = 'https://www.gov.cn/'
        }
        # 用原始字节 + 编码探测解码，避免 Invoke-WebRequest 对中文站点的错误解码
        $ms = $r.RawContentStream -as [System.IO.MemoryStream]
        if ($ms) { return Decode-Html $ms.ToArray() }
        return Decode-Html ([System.Text.Encoding]::UTF8.GetBytes([string]$r.Content))
    } catch {
        Log ("  获取失败 [{0}]: {1}" -f $url, $_.Exception.Message)
        return $null
    }
}

function Read-TextFileAuto([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    return Decode-Html $bytes
}

function Get-DateFromUrl([string]$s) {
    $m = [regex]::Match($s, '(20\d{2})(\d{2})(\d{2})')
    if ($m.Success) { return '{0}-{1}-{2}' -f $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value }
    $m = [regex]::Match($s, '(20\d{2})[/\-](\d{1,2})[/\-](\d{1,2})')
    if ($m.Success) { return '{0}-{1:d2}-{2:d2}' -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value }
    return ''
}

function Get-DateFromText([string]$s) {
    $m = [regex]::Match($s, '20\d{2}[-./年]\d{1,2}[-./月]\d{1,2}')
    if (-not $m.Success) { $m = [regex]::Match($s, '20\d{2}年\d{1,2}月\d{1,2}日') }
    if ($m.Success) {
        $d = $m.Value -replace '年', '-' -replace '月', '-' -replace '日', '' -replace '\.', '-' -replace '/', '-'
        return $d
    }
    return ''
}

function Get-LastDateFromText([string]$s) {
    $ms = [regex]::Matches($s, '20\d{2}[-./年]\d{1,2}[-./月]\d{1,2}')
    if ($ms.Count -eq 0) { return '' }
    $d = $ms[$ms.Count - 1].Value -replace '年', '-' -replace '月', '-' -replace '日', '' -replace '\.', '-' -replace '/', '-'
    return $d
}

function Resolve-Url([string]$base, [string]$href) {
    try { return ([System.Uri]::new([System.Uri]$base, $href)).AbsoluteUri }
    catch { return $href }
}

function Test-Keyword([string]$title) {
    $t = $title.ToLowerInvariant()
    foreach ($kw in $Keywords) {
        if ($kw -and $t.Contains($kw.ToLowerInvariant())) { return $kw }
    }
    return $null
}

function Clean-Title([string]$s) {
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    $s = $s -replace '\s+', ' '
    $s = $s.Trim()
    $s = $s -replace '\|', '｜' -replace '\[', '［' -replace '\]', '］'
    return $s
}

# ---------- 抓取并解析 ----------
$newItems   = @()
$allMatched = @{}

$opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
$rx  = [regex]::new('(?<pre>.{0,60})<a\b[^>]*href=["''](?<href>[^"'']+)["''][^>]*>(?<title>[^<]{4,})</a>(?=(?<tail>.{0,220}))', $opt)
$cutoff = (Get-Date).Date.AddDays(-$DaysBack)

foreach ($src in $Sources) {
    $name = $src.name
    $base = $src.base
    $url  = $src.url
    $html = $null

    if ($TestLocal) {
        $f = Join-Path $Root $src.testFile
        if (Test-Path $f) { $html = Read-TextFileAuto $f }
        else { Log "  [$name] 测试文件缺失: $f" }
    } else {
        $html = Get-PageHtml $url
    }
    if (-not $html) { continue }

    $ms = $rx.Matches($html)
    $srcMatched = @{}
    foreach ($m in $ms) {
        $href  = $m.Groups['href'].Value
        $title = $m.Groups['title'].Value
        $tail  = $m.Groups['tail'].Value
        $pre   = $m.Groups['pre'].Value

        if ($href -match '^(javascript:|#|mailto:|tel:)') { continue }
        if ($href -match '\.(css|js|png|jpe?g|gif|ico|xml|pdf|docx?)(\?|$)') { continue }
        if ($href -match '(index|more|rss|search|sitemap|map)\.(htm|html|shtml)?$') { continue }
        if ($href -match '\.(htm|html|shtml)?$' -and $href -match '(liebiao|list)' ) { continue }

        $title2 = Clean-Title $title
        if ($title2.Length -lt 4 -or $title2.Length -gt 200) { continue }
        if ($title2 -match '首页|登录|注册|返回|更多|英文|中文|微信|微博|客户端|邮箱|无障碍|无障碍开关|电脑版') { continue }

        $kw = Test-Keyword $title2
        if (-not $kw) { continue }

        # 过滤明显非政策类动态：地方监管动态、留言选登Q&A、会议/活动/培训新闻、月度统计发布
        if ($title2 -match '监管办|监管局|监管机构') { continue }
        if ($title2 -match '？') { continue }
        if ($title2 -match '召开|党组会议|举行|庆祝|培训班|交流会|宣贯|巡视|调研|走访') { continue }
        if ($title2 -match '同比增长|交易电量|用电量|充电量|核发及交易数据') { continue }

        $abs  = Resolve-Url $base $href

        # 跳过跨域名外链（多为办事系统/门户链接，如 gec.nea.gov.cn、zzxy.nea.gov.cn）
        try {
            $absUri  = [System.Uri]::new($abs)
            $baseUri = [System.Uri]::new($base)
            if ($absUri.Host -ne $baseUri.Host) { continue }
        } catch { }

        $date = Get-DateFromUrl $href
        if ($src.dateBeforeLink) {
            # wap 等站点把日期放在链接前面的 <span> 里，优先取链接前最近的日期
            if (-not $date) { $date = Get-LastDateFromText $pre }
            if (-not $date) { $date = Get-DateFromText $tail }
        } else {
            if (-not $date) { $date = Get-DateFromText $tail }
        }
        # 无日期时，尝试 "URL中的年份 + 文本中的月-日" 组合（如 samr：URL含2026，列表含09-26）
        if (-not $date) {
            $ym = [regex]::Match($href, '(20\d{2})')
            $md = [regex]::Match($tail, '(\d{1,2})-(\d{1,2})')
            if ($ym.Success -and $md.Success) {
                $date = '{0}-{1:d2}-{2:d2}' -f [int]$ym.Groups[1].Value, [int]$md.Groups[1].Value, [int]$md.Groups[2].Value
            }
        }
        # 无日期 → 视为导航/门户链接（政策文件必有发布日期），跳过
        if (-not $date) { continue }

        # 日期窗口过滤
        try {
            $d = [datetime]::ParseExact($date, 'yyyy-M-d', $null)
            if ($d -lt $cutoff) { continue }
        } catch { }

        if (-not $srcMatched.ContainsKey($abs)) {
            $srcMatched[$abs] = [pscustomobject]@{ source=$name; title=$title2; url=$abs; date=$date; kw=$kw }
        }
    }

    $cnt = $srcMatched.Count
    foreach ($k in $srcMatched.Keys) {
        $it = $srcMatched[$k]
        if (-not $allMatched.ContainsKey($k)) { $allMatched[$k] = $it }
        if (-not $Seen.ContainsKey($k)) { $newItems += $it }
    }
    Log ("  [$name] 命中 $cnt 条")
}

# ---------- 输出 ----------
Log ("== 检查完成：本轮命中 $($allMatched.Count) 条，其中新增 $($newItems.Count) 条 ==")

if ($newItems.Count -gt 0) {
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $reportPath = Join-Path $ReportsDir "新增_$stamp.md"
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# 政策新增提醒')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('检查时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| 来源 | 日期 | 标题 | 命中关键词 |')
    [void]$sb.AppendLine('|------|------|------|-----------|')
    foreach ($it in ($newItems | Sort-Object source, date)) {
        $d = if ($it.date) { $it.date } else { '—' }
        [void]$sb.AppendLine("| $($it.source) | $d | [$($it.title)]($($it.url)) | $($it.kw) |")
    }
    $report = $sb.ToString()
    Set-Content -Path $reportPath -Value $report -Encoding UTF8
    Log ("报告已写入: $reportPath")

    # 桌面气泡提醒（仅交互会话有效，失败不致命）
    try {
        [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Information
        $ni.BalloonTipTitle = "政策追踪：发现 $($newItems.Count) 条新增"
        $ni.BalloonTipText = ($newItems | Select-Object -First 3 -ExpandProperty title) -join "`n"
        $ni.Visible = $true
        $ni.ShowBalloonTip(10000)
        Start-Sleep -Seconds 2
        $ni.Dispose()
    } catch { }
} else {
    Log '本次无新增（所有命中均已记录）。'
}

# ---------- 更新 seen.json（写入全部命中，避免下次重复） ----------
foreach ($k in $allMatched.Keys) {
    $it = $allMatched[$k]
    if (-not $Seen.ContainsKey($k)) {
        $Seen[$k] = [pscustomobject]@{ url=$k; title=$it.title; source=$it.source; date=$it.date; kw=$it.kw; added=(Get-Date -Format 'yyyy-MM-dd') }
    }
}
$seenList = @($Seen.Values | Sort-Object added, url)
$seenList | ConvertTo-Json -Compress | Set-Content -Path $SeenFile -Encoding UTF8
Log "seen.json 已更新，共 $($Seen.Keys.Count) 条。"

# ---------- 生成网页台账 ----------
$TemplateFile = Join-Path $Root 'dashboard-template.html'
$DashFile     = Join-Path $Root '政策追踪.html'

if (Test-Path $TemplateFile) {
    # 从 seen.json 取全量已记录条目，日期归一化后按政策日期倒序
    $dashItems = @($Seen.Values | ForEach-Object {
        $ds = [string]$_.date
        try { $ds = ([datetime]::ParseExact($_.date, 'yyyy-M-d', $null)).ToString('yyyy-MM-dd') } catch { }
        [pscustomobject]@{ source = $_.source; title = $_.title; url = $_.url; date = $ds; kw = $_.kw }
    } | Sort-Object date -Descending)

    if ($dashItems.Count -eq 0) {
        $json = '[]'
    } elseif ($dashItems.Count -eq 1) {
        $json = '[' + ($dashItems | ConvertTo-Json -Compress) + ']'
    } else {
        $json = $dashItems | ConvertTo-Json -Compress
    }

    $html = Get-Content -Path $TemplateFile -Raw -Encoding UTF8
    $html = $html.Replace('/*__DATA__*/', $json)
    $html = $html.Replace('/*__KW_COUNT__*/', [string]$Keywords.Count)
    $html = $html.Replace('/*__GENERATED__*/', (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    Set-Content -Path $DashFile -Value $html -Encoding UTF8
    # 同时输出 index.html 供 GitHub Pages 根目录默认页使用
    $IdxFile = Join-Path $Root 'index.html'
    Set-Content -Path $IdxFile -Value $html -Encoding UTF8
    Log "网页台账已更新: $DashFile（共 $($dashItems.Count) 条）"

    # 提交并推送到 GitHub Pages（非 git 仓库 / 无远端 / 网络失败均不致命）
    try {
        if (Test-Path (Join-Path $Root '.git')) {
            git -C $Root add -A *> $null
            git -C $Root diff --cached --quiet
            if ($LASTEXITCODE -eq 0) {
                Log '台账无变化，跳过 git 提交。'
            } else {
                git -C $Root commit -m "更新台账 $(Get-Date -Format 'yyyy-MM-dd')" -m "Co-Authored-By: Claude Code <noreply@anthropic.com>" *> $null
                $pushed = $false
                for ($i = 0; $i -lt 3; $i++) {
                    git -C $Root push *> $null
                    if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
                    Start-Sleep -Seconds 10
                }
                if ($pushed) { Log '已推送到 GitHub Pages。' }
                else { Log 'git push 连续失败（可能网络问题），本次检查不受影响。' }
            }
        }
    } catch {
        Log "git 推送环节异常（不影响本次检查）：$($_.Exception.Message)"
    }
} else {
    Log "模板缺失，跳过网页生成: $TemplateFile"
}
