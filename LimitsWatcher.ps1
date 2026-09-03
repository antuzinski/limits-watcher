<#
    Limits Watcher  —  уведомление о восстановлении лимитов Codex / Claude Code
    ПОЛНОСТЬЮ ЛОКАЛЬНАЯ ВЕРСИЯ: никаких запросов к API и никаких запусков CLI.

    Откуда берутся данные:
      Codex  — ~/.codex/sessions/**/rollout-*.jsonl, события token_count содержат
               rate_limits: primary/secondary с used_percent и resets_in_seconds.
      Claude — статуслайн-хук: Claude Code на каждом ходе передаёт в него JSON с
               rate_limits.five_hour/seven_day (used_percentage, resets_at).
               Скрипт-перехватчик складывает эти цифры в файл.
               Запасной вариант — строка "usage limit reached|<epoch>" в транскриптах.

    Запуск:
      .\monitor_v7.ps1 -Diag                  — показать всё, что видно локально
      .\monitor_v7.ps1 -InstallStatusline     — поставить перехватчик для Claude
      .\monitor_v7.ps1 -UninstallStatusline   — вернуть статуслайн как было
      .\monitor_v7.ps1 -TestToast             — проверить уведомления
      .\monitor_v7.ps1 -Install               — в автозапуск (Планировщик задач)
      .\monitor_v7.ps1 -Uninstall             — убрать из автозапуска
      .\monitor_v7.ps1                        — интерактивно
      .\monitor_v7.ps1 -Background            — рабочий режим (так его зовёт Планировщик)
#>
[CmdletBinding()]
param(
    [switch]$Background,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$InstallStartup,
    [switch]$UninstallStartup,
    [switch]$InstallStatusline,
    [switch]$CheckStatusline,
    [switch]$UninstallStatusline,
    [switch]$Setup,
    [switch]$TestToast,
    [switch]$Diag
)

$ErrorActionPreference = 'Continue'

# ==================== НАСТРОЙКИ ====================
$TaskName          = 'Limits_Watcher'
$AppId             = 'Limits.Watcher'
$DataDir           = Join-Path $env:LOCALAPPDATA 'LimitsWatcher'
$LogFile           = Join-Path $DataDir 'monitor.log'
$StateFile         = Join-Path $DataDir 'state.json'
$ClaudeRateFile    = Join-Path $DataDir 'claude_rate.json'
$TapScript         = Join-Path $DataDir 'cc-statusline-tap.ps1'
$TapRawFile        = Join-Path $DataDir 'claude_statusline_raw.json'
$TapErrFile        = Join-Path $DataDir 'tap_error.log'

$CodexSessionsDir  = Join-Path $env:USERPROFILE '.codex\sessions'
$ClaudeProjectsDir = Join-Path $env:USERPROFILE '.claude\projects'
$ClaudeSettings    = Join-Path $env:USERPROFILE '.claude\settings.json'

$LimitThresholdPct = 99      # с какого процента окна считаем лимит исчерпанным
$PollMinutes       = 3       # чтение локальных файлов дешёвое, можно часто
$Sources           = @('Codex', 'Claude')
# ===================================================


function Write-TextNoBom {
    # PS 5.1 в Out-File -Encoding utf8 всегда ставит BOM, а JSON-парсеры
    # (в том числе в Claude Code) на нём спотыкаются. Пишем без BOM.
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-Log {
    param([string]$Message)
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
    "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $Message" |
        Out-File -FilePath $LogFile -Append -Encoding utf8
}

# ---------- Уведомления ----------
function Register-ToastAppId {
    try {
        $key = "HKCU:\SOFTWARE\Classes\AppUserModelId\$AppId"
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name 'DisplayName'        -Value 'Limits Watcher' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $key -Name 'ShowInActionCenter' -Value 1                  -PropertyType DWord  -Force | Out-Null
    } catch { Write-Log "AppId register failed: $($_.Exception.Message)" }
}

function Show-Notification {
    param([string]$Title, [string]$Message)
    $shown = $false
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
        $t = [Security.SecurityElement]::Escape($Title)
        $m = [Security.SecurityElement]::Escape($Message)
        $xml = @"
<toast scenario="reminder" launch="dismiss">
  <visual><binding template="ToastGeneric"><text>$t</text><text>$m</text></binding></visual>
  <audio src="ms-winsoundevent:Notification.Reminder"/>
  <actions><action content="OK" arguments="dismiss" activationType="system"/></actions>
</toast>
"@
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
        $shown = $true
    } catch { Write-Log "TOAST FAIL: $($_.Exception.Message)" }

    if (-not $shown) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            $ni = New-Object System.Windows.Forms.NotifyIcon
            $ni.Icon = [System.Drawing.SystemIcons]::Information
            $ni.Visible = $true
            $ni.BalloonTipTitle = $Title
            $ni.BalloonTipText  = $Message
            $ni.ShowBalloonTip(20000)
            Start-Sleep -Seconds 12
            $ni.Dispose()
            $shown = $true
        } catch { Write-Log "BALLOON FAIL: $($_.Exception.Message)" }
    }
    return $shown
}

# ---------- Общая оценка состояния ----------
function New-State {
    param([string]$State, [string]$Raw, $ResetsAt, [double]$Used = -1)
    return @{ State = $State; Raw = $Raw; ResetsAt = $ResetsAt; Used = $Used }
}

function Resolve-Window {
    # Единое правило: лимит исчерпан, только если процент выше порога
    # И время сброса ещё не наступило. Как только оно прошло — состояние ok,
    # даже если свежих данных нет. Именно это и ловит момент сброса.
    param([double]$Used, $ResetsAt, [string]$Label)
    $now = Get-Date
    if ($ResetsAt -and $Used -ge $LimitThresholdPct -and $ResetsAt -gt $now) {
        return New-State 'limited' "$Label $([Math]::Round($Used,1))%, сброс в $($ResetsAt.ToString('HH:mm'))" $ResetsAt $Used
    }
    if ($Used -ge $LimitThresholdPct -and -not $ResetsAt) {
        return New-State 'limited' "$Label $([Math]::Round($Used,1))%, время сброса неизвестно" $null $Used
    }
    return New-State 'ok' "$Label $([Math]::Round($Used,1))%$(if ($ResetsAt) { ", окно до $($ResetsAt.ToString('HH:mm'))" })" $ResetsAt $Used
}

# ---------- CODEX: чтение rollout-файлов ----------
function Get-CodexState {
    if (-not (Test-Path $CodexSessionsDir)) {
        return New-State 'unknown' "нет папки $CodexSessionsDir" $null
    }
    $files = Get-ChildItem $CodexSessionsDir -Filter 'rollout-*.jsonl' -Recurse -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 8
    if (-not $files) { return New-State 'unknown' 'сессий Codex не найдено' $null }

    foreach ($f in $files) {
        # @() обязательно: файл из одной строки иначе индексируется посимвольно
        $lines = @(Get-Content $f.FullName -Tail 800 -ErrorAction SilentlyContinue)
        if (-not $lines) { continue }
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $l = $lines[$i]
            if ($l -notmatch '"rate_limits"')      { continue }
            if ($l -match '"rate_limits"\s*:\s*null') { continue }
            $o = $null
            try { $o = $l | ConvertFrom-Json } catch { continue }
            $rl = $o.payload.rate_limits
            if (-not $rl) { $rl = $o.rate_limits }
            if (-not $rl) { continue }

            $ts = $f.LastWriteTime
            if ($o.timestamp) { try { $ts = [DateTimeOffset]::Parse($o.timestamp).LocalDateTime } catch { } }

            $best = $null
            foreach ($w in @(@{K='primary';N='5ч'}, @{K='secondary';N='нед'})) {
                $win = $rl.($w.K)
                if (-not $win) { continue }
                $used = [double]$win.used_percent
                $rst  = $null
                if ($win.resets_in_seconds -ne $null) { $rst = $ts.AddSeconds([double]$win.resets_in_seconds) }
                $cand = Resolve-Window -Used $used -ResetsAt $rst -Label $w.N
                if (-not $best -or ($cand.State -eq 'limited' -and $best.State -ne 'limited')) { $best = $cand }
                elseif ($best.State -eq $cand.State -and $cand.Used -gt $best.Used) { $best = $cand }
            }
            if ($best) {
                $best.Raw = "$($best.Raw) [данные от $($ts.ToString('dd.MM HH:mm'))]"
                return $best
            }
        }
    }
    return New-State 'unknown' 'в свежих сессиях Codex нет данных о лимитах (поработайте в codex, TUI их записывает)' $null
}

# ---------- CLAUDE: файл от статуслайн-перехватчика ----------
function Get-ClaudeStateFromTap {
    if (-not (Test-Path $ClaudeRateFile)) { return $null }
    try {
        $j = Get-Content $ClaudeRateFile -Raw | ConvertFrom-Json
    } catch { return $null }

    $at = if ($j.at) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$j.at).LocalDateTime } else { (Get-Item $ClaudeRateFile).LastWriteTime }
    $best = $null
    foreach ($w in @(@{U='five_hour_used'; R='five_hour_resets_at'; N='5ч'},
                     @{U='seven_day_used'; R='seven_day_resets_at'; N='7д'})) {
        if ($j.($w.U) -eq $null) { continue }
        $used = [double]$j.($w.U)
        $rst  = $null
        if ($j.($w.R)) { $rst = [DateTimeOffset]::FromUnixTimeSeconds([int64]$j.($w.R)).LocalDateTime }
        $cand = Resolve-Window -Used $used -ResetsAt $rst -Label $w.N
        if (-not $best -or ($cand.State -eq 'limited' -and $best.State -ne 'limited')) { $best = $cand }
        elseif ($best.State -eq $cand.State -and $cand.Used -gt $best.Used) { $best = $cand }
    }
    if ($best) { $best.Raw = "$($best.Raw) [данные от $($at.ToString('dd.MM HH:mm'))]" }
    return $best
}

# ---------- CLAUDE: запасной разбор транскриптов ----------
function Get-ClaudeStateFromTranscripts {
    if (-not (Test-Path $ClaudeProjectsDir)) { return $null }
    try {
        $files = Get-ChildItem $ClaudeProjectsDir -Filter *.jsonl -Recurse -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 5
        foreach ($f in $files) {
            $lines = @(Get-Content $f.FullName -Tail 300 -ErrorAction SilentlyContinue)
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                if ($lines[$i] -match 'usage limit reached\|(\d{10,13})') {
                    $num = [int64]$Matches[1]
                    if ($num -gt 100000000000) { $num = [int64]($num / 1000) }
                    $rst = [DateTimeOffset]::FromUnixTimeSeconds($num).LocalDateTime
                    if ($rst -gt (Get-Date)) {
                        return New-State 'limited' "по транскрипту: сброс в $($rst.ToString('HH:mm'))" $rst 100
                    }
                    return New-State 'ok' "по транскрипту: лимит сброшен в $($rst.ToString('HH:mm'))" $rst 0
                }
            }
        }
    } catch { Write-Log "transcript scan failed: $($_.Exception.Message)" }
    return $null
}

function Get-ClaudeState {
    $s = Get-ClaudeStateFromTap
    if ($s) { return $s }
    $s = Get-ClaudeStateFromTranscripts
    if ($s) { return $s }
    return New-State 'unknown' 'нет локальных данных — поставьте перехватчик: -InstallStatusline' $null
}

function Get-SourceState {
    param([string]$Name)
    switch ($Name) {
        'Codex'  { return Get-CodexState }
        'Claude' { return Get-ClaudeState }
    }
    return New-State 'unknown' 'неизвестный источник' $null
}

# ---------- Установка перехватчика статуслайна ----------
function Install-Statusline {
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

    $prev = ''
    $settings = $null
    if (Test-Path $ClaudeSettings) {
        Copy-Item $ClaudeSettings "$ClaudeSettings.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
        try { $settings = Get-Content $ClaudeSettings -Raw | ConvertFrom-Json } catch { }
        if ($settings.statusLine.command) {
            $prev = [string]$settings.statusLine.command
            if ($prev -like "*cc-statusline-tap*") { $prev = '' }   # уже наш
        }
    }
    if (-not $settings) { $settings = New-Object psobject }

    $tap = @'
# Перехватчик статуслайна Claude Code: складывает rate_limits в файл.
$ErrorActionPreference = 'SilentlyContinue'
$raw = [Console]::In.ReadToEnd()
$dir = Join-Path $env:LOCALAPPDATA 'LimitsWatcher'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$model = ''
$line  = ''
# Диагностика: всегда сохраняем то, что реально прислал Claude Code
try { [IO.File]::WriteAllText((Join-Path $dir 'claude_statusline_raw.json'), $raw, (New-Object System.Text.UTF8Encoding($false))) } catch { }
try {
    $j = $raw | ConvertFrom-Json
    if ($j.model.display_name) { $model = $j.model.display_name }
    if ($j.rate_limits) {
        $o = [ordered]@{
            five_hour_used      = $j.rate_limits.five_hour.used_percentage
            five_hour_resets_at = $j.rate_limits.five_hour.resets_at
            seven_day_used      = $j.rate_limits.seven_day.used_percentage
            seven_day_resets_at = $j.rate_limits.seven_day.resets_at
            at                  = [int64][Math]::Floor((Get-Date).ToUniversalTime().Subtract([datetime]'1970-01-01').TotalSeconds)
        }
        [IO.File]::WriteAllText((Join-Path $dir 'claude_rate.json'), ($o | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
        $line = "5h {0:N0}% | 7d {1:N0}%" -f [double]$j.rate_limits.five_hour.used_percentage, [double]$j.rate_limits.seven_day.used_percentage
    }
} catch {
    try { "$(Get-Date -Format s)  $($_.Exception.Message)" | Out-File (Join-Path $dir 'tap_error.log') -Append -Encoding utf8 } catch { }
}

$prev = '__PREV__'
if ($prev) {
    try { $raw | & ([scriptblock]::Create($prev)); exit } catch { }
}
if ($model -and $line) { "$model | $line" } elseif ($model) { $model } else { 'claude' }
'@
    $tap = $tap.Replace('__PREV__', $prev.Replace("'", "''"))
    Write-TextNoBom -Path $TapScript -Text $tap

    $cmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$TapScript`""
    $sl  = New-Object psobject
    $sl  | Add-Member -NotePropertyName 'type'    -NotePropertyValue 'command'
    $sl  | Add-Member -NotePropertyName 'command' -NotePropertyValue $cmd
    if ($settings.PSObject.Properties.Name -contains 'statusLine') { $settings.statusLine = $sl }
    else { $settings | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue $sl }

    $dir = Split-Path $ClaudeSettings -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-TextNoBom -Path $ClaudeSettings -Text ($settings | ConvertTo-Json -Depth 20)

    Write-Host "✅ Перехватчик установлен: $TapScript" -ForegroundColor Green
    if ($prev) { Write-Host "   Прежний статуслайн сохранён и будет вызываться следом." -ForegroundColor DarkGray }
    Write-Host "   Откройте claude и сделайте один запрос — после первого ответа появятся цифры." -ForegroundColor Yellow
}

function Uninstall-Statusline {
    if (-not (Test-Path $ClaudeSettings)) { Write-Host 'settings.json не найден.'; return }
    try { $settings = Get-Content $ClaudeSettings -Raw | ConvertFrom-Json } catch { Write-Host 'Не удалось разобрать settings.json'; return }
    if ($settings.statusLine.command -like '*cc-statusline-tap*') {
        $settings.PSObject.Properties.Remove('statusLine')
        Write-TextNoBom -Path $ClaudeSettings -Text ($settings | ConvertTo-Json -Depth 20)
        Write-Host '✅ Перехватчик убран. Если у вас был свой статуслайн — верните его из резервной копии settings.json.bak-*' -ForegroundColor Green
    } else {
        Write-Host 'Наш перехватчик в settings.json не прописан — ничего не меняю.' -ForegroundColor Yellow
    }
}


function Test-Statusline {
    Write-Host '=== Проверка перехватчика статуслайна ===' -ForegroundColor Cyan

    Write-Host "`n1. settings.json: $ClaudeSettings" -ForegroundColor Yellow
    if (-not (Test-Path $ClaudeSettings)) {
        Write-Host '   ФАЙЛА НЕТ — запустите -InstallStatusline' -ForegroundColor Red
    } else {
        $bytes = [IO.File]::ReadAllBytes($ClaudeSettings)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            Write-Host '   ⚠ Файл с BOM — Claude Code может его не прочитать. Перезапустите -InstallStatusline (в v8 пишется без BOM).' -ForegroundColor Red
        }
        $txt = [IO.File]::ReadAllText($ClaudeSettings)
        try {
            $j = $txt | ConvertFrom-Json
            if ($j.statusLine) {
                Write-Host "   type   : $($j.statusLine.type)"
                Write-Host "   command: $($j.statusLine.command)"
            } else { Write-Host '   Блока statusLine нет!' -ForegroundColor Red }
        } catch { Write-Host "   JSON не разбирается: $($_.Exception.Message)" -ForegroundColor Red }
    }

    Write-Host "`n2. Скрипт перехватчика: $TapScript" -ForegroundColor Yellow
    Write-Host $(if (Test-Path $TapScript) { '   есть' } else { '   НЕТ' }) -ForegroundColor $(if (Test-Path $TapScript) { 'Green' } else { 'Red' })

    Write-Host "`n3. Что реально прислал Claude Code: $TapRawFile" -ForegroundColor Yellow
    if (Test-Path $TapRawFile) {
        $raw = [IO.File]::ReadAllText($TapRawFile)
        Write-Host "   обновлён: $((Get-Item $TapRawFile).LastWriteTime)"
        Write-Host "   поля верхнего уровня:" -NoNewline
        try {
            $o = $raw | ConvertFrom-Json
            Write-Host (' ' + (($o.PSObject.Properties.Name) -join ', '))
            if ($o.rate_limits) {
                Write-Host '   ✅ rate_limits присутствует:' -ForegroundColor Green
                Write-Host ('      ' + ($o.rate_limits | ConvertTo-Json -Compress))
            } else {
                Write-Host '   ⚠ rate_limits НЕТ в payload.' -ForegroundColor Red
                Write-Host '     Так бывает на API-ключе вместо подписки Pro/Max, либо в вашей версии Claude Code это поле не отдаётся.' -ForegroundColor DarkGray
                Write-Host '     Полный payload лежит в файле выше — пришлите его, подберём другой источник.' -ForegroundColor DarkGray
            }
        } catch { Write-Host " не разбирается: $($_.Exception.Message)" -ForegroundColor Red }
    } else {
        Write-Host '   Файла нет — значит перехватчик ни разу не запускался.' -ForegroundColor Red
        Write-Host '   Проверьте: статуслайн виден внизу окна claude? Если нет — Claude Code не выполняет команду.' -ForegroundColor DarkGray
    }

    Write-Host "`n4. Ошибки перехватчика: $TapErrFile" -ForegroundColor Yellow
    if (Test-Path $TapErrFile) { Get-Content $TapErrFile -Tail 5 | ForEach-Object { Write-Host "   $_" -ForegroundColor Red } }
    else { Write-Host '   пусто' }

    Write-Host "`n5. Прогон перехватчика на тестовом payload" -ForegroundColor Yellow
    if (Test-Path $TapScript) {
        $sample = '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":' +
                  [int64][Math]::Floor(((Get-Date).ToUniversalTime().AddHours(2)).Subtract([datetime]'1970-01-01').TotalSeconds) +
                  '},"seven_day":{"used_percentage":30,"resets_at":' +
                  [int64][Math]::Floor(((Get-Date).ToUniversalTime().AddDays(3)).Subtract([datetime]'1970-01-01').TotalSeconds) + '}}}'
        $outText = $sample | & powershell -NoProfile -ExecutionPolicy Bypass -File $TapScript
        Write-Host "   вывод статуслайна: $outText"
        Write-Host $(if (Test-Path $ClaudeRateFile) { "   ✅ claude_rate.json записан: $([IO.File]::ReadAllText($ClaudeRateFile))" } else { '   ❌ claude_rate.json не появился' })
    }
}



# ---------- Установка «в один клик» ----------
function Invoke-Setup {
    Write-Host ''
    Write-Host '==================================================' -ForegroundColor Cyan
    Write-Host '   LIMITS WATCHER — установка' -ForegroundColor Cyan
    Write-Host '   Уведомление, когда лимиты Codex / Claude Code' -ForegroundColor Cyan
    Write-Host '   снова доступны. Всё считается локально.' -ForegroundColor Cyan
    Write-Host '==================================================' -ForegroundColor Cyan

    Write-Host ''
    Write-Host '[1/4] Регистрирую источник уведомлений...' -ForegroundColor Yellow
    Register-ToastAppId
    Write-Host '      готово'

    Write-Host ''
    Write-Host '[2/4] Проверяю уведомления...' -ForegroundColor Yellow
    $toastOk = Show-Notification -Title 'Limits Watcher 🔔' -Message 'Проверка связи. Так будет выглядеть сообщение о сбросе лимитов.'
    if ($toastOk) {
        Write-Host '      отправлено — посмотрите в правый нижний угол' -ForegroundColor Green
    } else {
        Write-Host '      НЕ УДАЛОСЬ. Смотрите лог: ' -ForegroundColor Red -NoNewline; Write-Host $LogFile
    }

    Write-Host ''
    Write-Host '[3/4] Подключаю Claude Code (перехватчик статуслайна)...' -ForegroundColor Yellow
    Install-Statusline

    Write-Host ''
    Write-Host '[4/4] Ставлю в автозапуск...' -ForegroundColor Yellow
    Install-Startup

    Write-Host ''
    Write-Host '=== Что видно прямо сейчас ===' -ForegroundColor Cyan
    foreach ($n in $Sources) {
        $st = Get-SourceState $n
        $color = switch ($st.State) { 'ok' { 'Green' } 'limited' { 'Yellow' } default { 'DarkGray' } }
        Write-Host ("  {0,-7} {1,-8} {2}" -f $n, $st.State, $st.Raw) -ForegroundColor $color
    }

    Write-Host ''
    Write-Host 'Готово. Что дальше:' -ForegroundColor Green
    Write-Host '  • Если Claude показан как unknown — откройте claude, задайте любой вопрос,'
    Write-Host '    и внизу окна появится строка вида "Opus | 5h 4% | 7d 12%".'
    Write-Host '  • Монитор молчит, пока вы не упрётесь в лимит. Это нормально.'
    Write-Host '  • Уведомление придёт в течение нескольких минут после сброса и будет'
    Write-Host '    висеть, пока вы его не закроете.'
    Write-Host ''
    Write-Host "  Лог: $LogFile" -ForegroundColor DarkGray
    Write-Host ''
}

# ---------- Автозапуск через папку «Автозагрузка» (без прав администратора) ----------
function Get-StartupLnk {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'Limits Watcher.lnk'
}

function Install-Startup {
    $vbs = Join-Path $DataDir 'run-hidden.vbs'
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

    # VBS-обёртка нужна только чтобы при входе не мигало окно консоли
    $vbsText = @"
Set sh = CreateObject("WScript.Shell")
sh.Run """$(Join-Path $PSHOME 'powershell.exe')"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$PSCommandPath"" -Background", 0, False
"@
    Write-TextNoBom -Path $vbs -Text $vbsText

    $lnkPath = Get-StartupLnk
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath       = "$env:SystemRoot\System32\wscript.exe"
    $lnk.Arguments        = "`"$vbs`""
    $lnk.WorkingDirectory = $DataDir
    $lnk.Description      = 'Мониторинг восстановления лимитов Codex / Claude Code'
    $lnk.Save()

    Write-Host "✅ Автозапуск через Автозагрузку: $lnkPath" -ForegroundColor Green
    Start-Process -FilePath "$env:SystemRoot\System32\wscript.exe" -ArgumentList "`"$vbs`"" | Out-Null
    Write-Host "   Монитор запущен прямо сейчас. Лог: $LogFile" -ForegroundColor Green
}

function Uninstall-Startup {
    $lnkPath = Get-StartupLnk
    if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force; Write-Host "Ярлык автозапуска удалён: $lnkPath" }
    else { Write-Host 'Ярлыка автозапуска нет.' }
    Get-Process powershell -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*monitor_v9*' } |
        ForEach-Object { try { $_.Kill() } catch { } }
}

# ---------- Автозапуск через Планировщик задач ----------
function Install-Task {
    $exe     = Join-Path $PSHOME 'powershell.exe'
    $argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Background"
    $action   = New-ScheduledTaskAction -Execute $exe -Argument $argLine
    $trigger  = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
                    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -StartWhenAvailable
    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Description 'Мониторинг восстановления лимитов Codex / Claude Code' -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Host "❌ Планировщик отказал: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '   Обычно это старая задача, созданная из-под администратора: её нельзя перезаписать обычными правами.' -ForegroundColor Yellow
        Write-Host '   Варианты:' -ForegroundColor Yellow
        Write-Host '     1) Убрать старую задачу из PowerShell от администратора:' -ForegroundColor Yellow
        Write-Host "        Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false" -ForegroundColor Gray
        Write-Host '     2) Обойтись без Планировщика — автозапуск через Автозагрузку, права не нужны:' -ForegroundColor Yellow
        Write-Host "        .\$(Split-Path $PSCommandPath -Leaf) -InstallStartup" -ForegroundColor Gray
        return $false
    }
}

# ==================== ТОЧКА ВХОДА ====================

if ($Setup)               { Invoke-Setup;        return }
if ($CheckStatusline)     { Test-Statusline;     return }
if ($InstallStatusline)   { Install-Statusline;   return }
if ($UninstallStatusline) { Uninstall-Statusline; return }

if ($TestToast) {
    Register-ToastAppId
    $ok = Show-Notification -Title 'Limits Watcher 🔔' -Message 'Если вы это видите — уведомления работают.'
    Write-Host $(if ($ok) { '✅ Уведомление отправлено.' } else { "❌ Не удалось показать уведомление, смотрите лог: $LogFile" })
    return
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Задача '$TaskName' удалена."
    return
}

if ($Install) {
    if (Install-Task) {
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "✅ Задача '$TaskName' создана и запущена. Лог: $LogFile" -ForegroundColor Green
    }
    return
}

if ($InstallStartup)   { Install-Startup;   return }
if ($UninstallStartup) { Uninstall-Startup; return }

if ($Diag) {
    Write-Host '=== Локальные источники ===' -ForegroundColor Cyan
    Write-Host ("Codex sessions : {0}" -f $(if (Test-Path $CodexSessionsDir) { $CodexSessionsDir } else { "НЕТ ($CodexSessionsDir)" })) -ForegroundColor DarkGray
    Write-Host ("Claude tap     : {0}" -f $(if (Test-Path $ClaudeRateFile)   { $ClaudeRateFile }   else { 'не установлен (-InstallStatusline)' })) -ForegroundColor DarkGray
    Write-Host ("Claude проекты : {0}" -f $(if (Test-Path $ClaudeProjectsDir){ $ClaudeProjectsDir }else { 'НЕТ' })) -ForegroundColor DarkGray
    foreach ($n in $Sources) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $s  = Get-SourceState $n
        $sw.Stop()
        Write-Host ''
        Write-Host ("===== {0} =====" -f $n) -ForegroundColor Cyan
        Write-Host ("состояние: {0}   ({1:N2} c)" -f $s.State, $sw.Elapsed.TotalSeconds) -ForegroundColor Yellow
        Write-Host ("детали   : {0}" -f $s.Raw)
    }
    return
}

if (-not $Background) {
    Write-Host '=== Limits Watcher — локальная проверка ===' -ForegroundColor Cyan
    foreach ($n in $Sources) {
        $s = Get-SourceState $n
        Write-Host ("  {0,-7} -> {1}" -f $n, $s.State) -ForegroundColor Yellow
        Write-Host ("           {0}" -f $s.Raw) -ForegroundColor DarkGray
    }
    Write-Host ''
    $choice = Read-Host 'Поставить монитор в автозапуск (Планировщик задач)? [Y/N]'
    if ($choice -match '^(y|н)') {
        if (Install-Task) {
            Start-ScheduledTask -TaskName $TaskName
            Write-Host "✅ Готово. Задача '$TaskName' работает в фоне. Лог: $LogFile" -ForegroundColor Green
        }
        return
    }
    Write-Host 'Работаю в этом окне. Ctrl+C для выхода.' -ForegroundColor Yellow
}

# ==================== ОСНОВНОЙ ЦИКЛ ====================
Register-ToastAppId
Write-Log '--- monitor v7 started (local sources) ---'

$state = @{}
if (Test-Path $StateFile) {
    try {
        (Get-Content $StateFile -Raw | ConvertFrom-Json).psobject.Properties |
            ForEach-Object { $state[$_.Name] = $_.Value }
    } catch { Write-Log "state load failed: $($_.Exception.Message)" }
}

while ($true) {
    $sleepMin = $PollMinutes

    foreach ($n in $Sources) {
        $res  = Get-SourceState $n
        $prev = $state[$n]
        Write-Log ("{0}: {1} (было: {2}) | {3}" -f $n, $res.State, $(if ($prev) { $prev } else { '-' }), $res.Raw)

        if ($res.State -eq 'limited') {
            $state[$n] = 'limited'
            if ($res.ResetsAt) {
                # спим почти до момента сброса, но просыпаемся хотя бы раз в час
                $mins = [int][Math]::Ceiling(($res.ResetsAt - (Get-Date)).TotalMinutes)
                if ($mins -gt $PollMinutes) { $sleepMin = [Math]::Max($PollMinutes, [Math]::Min(60, $mins)) }
            }
        }
        elseif ($res.State -eq 'ok') {
            if ($prev -eq 'limited') {
                $emoji = if ($n -eq 'Codex') { '🟢' } else { '🟣' }
                $sent  = Show-Notification -Title "$n доступен! $emoji" -Message "Лимиты восстановлены. $($res.Raw)"
                Write-Log ("NOTIFY {0} sent={1}" -f $n, $sent)
            }
            $state[$n] = 'ok'
        }
        # unknown — состояние не трогаем, чтобы не потерять переход limited -> ok
    }

    try { $state | ConvertTo-Json | Out-File -FilePath $StateFile -Encoding utf8 } catch { }
    Start-Sleep -Seconds ($sleepMin * 60)
}
