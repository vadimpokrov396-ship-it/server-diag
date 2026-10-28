#Requires -Version 3.0
<#
server-diag.ps1 - read-only health check of a Windows server or PC with a plain-language verdict (Russian / English).
Project: https://github.com/vadimpokrov396-ship-it/server-diag

The easy way: double-click ЗАПУСТИ-МЕНЯ.bat (Russian) or RUN-ME.bat (language of Windows). It asks for administrator
rights (UAC) for the full check; if you decline, a reduced check runs.
Manual run:
  powershell -NoProfile -ExecutionPolicy Bypass -File server-diag.ps1 [-Lang ru|en|auto] [-Days 30] [-OutDir C:\path] [-NoElevate] [-NoHtml]

SAFE: the script only READS - event logs, WMI/CIM, storage reliability counters, registry values. It installs nothing,
restarts nothing and changes no settings. "-ExecutionPolicy Bypass" applies to this one PowerShell process only.
The only file it writes is the HTML report (on the Desktop by default).
#>
[CmdletBinding()]
param(
    [ValidateSet('ru', 'en', 'auto')][string]$Lang = 'ru',
    [ValidateRange(1, 365)][int]$Days = 30,
    [string]$OutDir = '',
    [switch]$NoElevate,
    [switch]$Pause,
    [switch]$NoHtml,
    [switch]$NoOpen,
    [switch]$TestNoAdmin   # testing only: run the reduced (non-admin) check even when elevated
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
if ($Lang -eq 'auto') { if ((Get-UICulture).Name -like 'ru*') { $Lang = 'ru' } else { $Lang = 'en' } }
try { if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } } catch { }
$VERSION = '2.0'

function L([string]$ru, [string]$en) { if ($script:Lang -eq 'en') { $en } else { $ru } }

# ------------------------------------------------------------------ elevation (UAC); declined -> reduced check
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin -and -not $NoElevate -and $PSCommandPath) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Lang', $Lang, '-Days', $Days, '-NoElevate', '-Pause')
    if ($OutDir) { $a += @('-OutDir', ('"{0}"' -f $OutDir.TrimEnd('\'))) }
    if ($NoHtml) { $a += '-NoHtml' }
    if ($NoOpen) { $a += '-NoOpen' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Verb RunAs -ErrorAction Stop | Out-Null
        Write-Host (L 'Проверка продолжается в новом окне с правами администратора. Это окно можно закрыть.' 'The check continues in a new window with administrator rights. You can close this window.')
        exit 0
    } catch {
        Write-Host (L 'Права администратора не получены - выполняю сокращённую проверку (часть пунктов будет пропущена).' 'No administrator rights - running a reduced check (some items will be skipped).') -ForegroundColor Yellow
    }
}

if ($TestNoAdmin) { $IsAdmin = $false }
# ------------------------------------------------------------------ helpers
$T0 = Get-Date
$F = New-Object System.Collections.Generic.List[object]
$OK = @{}
$Notes = New-Object System.Collections.Generic.List[string]
$Limits = New-Object System.Collections.Generic.List[string]
$Tech = New-Object System.Text.StringBuilder

function Add-F([int]$Sev, [string]$Area, [int]$Score, [string]$Conf, [string]$Title, [string]$Why, [string]$Do, [string]$Ev = '') {
    if ($Conf -eq 'l') { $Score -= 10 }
    $script:F.Add([pscustomobject]@{ Sev = $Sev; Area = $Area; Score = $Score; Conf = $Conf; Title = $Title; Why = $Why; Do = $Do; Ev = $Ev; N = $script:F.Count })
}
function Raz([int]$n) { $a = $n % 10; $b = $n % 100; if ($a -ge 2 -and $a -le 4 -and ($b -lt 12 -or $b -gt 14)) { "$n раза" } else { "$n раз" } }   # Russian plural
function Note([string]$s) { $script:Notes.Add($s) }
function Limit([string]$s) { $script:Limits.Add($s) }
function Sec([string]$s) { [void]$script:Tech.AppendLine(''); [void]$script:Tech.AppendLine("=== $s") }
function Tech($o) { if ($null -ne $o) { $t = ($o | Out-String -Width 200).TrimEnd(); if ($t) { [void]$script:Tech.AppendLine($t) } } }
function Say([string]$s) { Write-Host $s -ForegroundColor DarkGray; [void]$script:Tech.AppendLine(('[{0:0.0} s] {1}' -f ((Get-Date) - $script:T0).TotalSeconds, $s)) }
function Fmt-Bytes([double]$b) {
    $u = (L 'Б КБ МБ ГБ ТБ' 'B KB MB GB TB').Split(' '); $i = 0
    while ($b -ge 1024 -and $i -lt 4) { $b /= 1024; $i++ }
    $ci = if ($script:Lang -eq 'en') { [Globalization.CultureInfo]::InvariantCulture } else { [Globalization.CultureInfo]::GetCultureInfo('ru-RU') }
    if ($b -lt 10) { [string]::Format($ci, '{0:0.0} {1}', $b, $u[$i]) } else { [string]::Format($ci, '{0:0} {1}', $b, $u[$i]) }
}
function Fmt-Date($d) { if ($null -eq $d) { return '?' }; if ($script:Lang -eq 'en') { $d.ToString('yyyy-MM-dd HH:mm') } else { $d.ToString('dd.MM.yyyy HH:mm') } }
function Fmt-Dur([timespan]$t) {
    if ($t.Days -gt 0) { L ("{0} дн. {1} ч" -f $t.Days, $t.Hours) ("{0}d {1}h" -f $t.Days, $t.Hours) }
    elseif ($t.Hours -gt 0) { L ("{0} ч {1} мин" -f $t.Hours, $t.Minutes) ("{0}h {1}m" -f $t.Hours, $t.Minutes) }
    else { L ("{0} мин" -f $t.Minutes) ("{0} min" -f $t.Minutes) }
}
function Get-Ev([hashtable]$fh, [int]$Max = 2000) { try { @(Get-WinEvent -FilterHashtable $fh -MaxEvents $Max -ErrorAction Stop) } catch { @() } }
function Ev-Lines($evs, [int]$n = 6) {
    @($evs | Sort-Object TimeCreated -Descending | Select-Object -First $n | ForEach-Object {
        $m = ($_.Message -replace '\s+', ' '); if (-not $m) { $m = '(no message text)' }
        if ($m.Length -gt 180) { $m = $m.Substring(0, 180) + '...' }
        '{0} [{1} {2}] {3}' -f $_.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $_.ProviderName, $_.Id, $m
    }) -join "`n"
}
function Top-Names($items, [int]$n = 5) { @($items | Group-Object | Sort-Object Count -Descending | Select-Object -First $n | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count }) -join ', ' }

Write-Host (L "server-diag $VERSION`: проверяю Windows. Только чтение - ничего не меняю (обычно 20-60 секунд)..." "server-diag $VERSION`: checking Windows. Read-only - nothing is changed (usually 20-60 seconds)...") -ForegroundColor Cyan

# ------------------------------------------------------------------ system
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpus = @(Get-CimInstance Win32_Processor)
$HostName = $env:COMPUTERNAME
$Cores = [int]$cs.NumberOfLogicalProcessors; if ($Cores -lt 1) { $Cores = [Environment]::ProcessorCount }
$Boot = $os.LastBootUpTime; $Up = (Get-Date) - $Boot
$IsVM = ("$($cs.Model) $($cs.Manufacturer)" -match 'Virtual|VMware|KVM|QEMU|HVM|Xen|VirtualBox|Bochs|OpenStack|Nutanix|Parallels|Amazon EC2|Google Compute|innotek')
$Kind = if ($IsVM) { L "виртуальный ($($cs.Manufacturer) $($cs.Model))" "virtual ($($cs.Manufacturer) $($cs.Model))" } else { L "физический ($($cs.Manufacturer) $($cs.Model))" "physical ($($cs.Manufacturer) $($cs.Model))" }
$Since = (Get-Date).AddDays(-$Days); $Since7 = (Get-Date).AddDays(-7); $Since1 = (Get-Date).AddDays(-1)
Sec 'System'
Tech ("{0} {1} build {2}, {3}; boot {4}; uptime {5}" -f $os.Caption, $os.Version, $os.BuildNumber, $os.OSArchitecture, $Boot, $Up)
Tech ("{0} {1}; CPU: {2}; logical CPUs: {3}; RAM: {4}; admin: {5}" -f $cs.Manufacturer, $cs.Model, ($cpus | Select-Object -First 1).Name, $Cores, (Fmt-Bytes $cs.TotalPhysicalMemory), $IsAdmin)
if (-not $IsAdmin) {
    Limit (L 'Запущено без прав администратора: не проверены износ и ошибки дисков (SMART), минидампы синих экранов и часть журналов. Для полной проверки запустите ЗАПУСТИ-МЕНЯ.bat и нажмите «Да» в окне запроса прав.' 'Not running as administrator: disk wear/errors (SMART), blue-screen minidumps and some logs were not checked. For the full check run RUN-ME.bat and click "Yes" in the permission prompt.')
}

# ------------------------------------------------------------------ quiet sampling window (CPU / processes / paging / disk latency)
Say (L '• замер нагрузки (3 секунды)...' '• measuring load (3 seconds)...')
function Snap {
    $c = Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'"
    $m = Get-CimInstance Win32_PerfRawData_PerfOS_Memory
    $d = Get-CimInstance Win32_PerfRawData_PerfDisk_PhysicalDisk -Filter "Name='_Total'"
    $p = @{}; foreach ($x in (Get-CimInstance Win32_PerfRawData_PerfProc_Process)) { if ($x.Name -ne '_Total' -and $x.Name -ne 'Idle') { $p["$($x.IDProcess)"] = @(($x.Name -replace '#\d+$', ''), [double]$x.PercentProcessorTime) } }
    [pscustomobject]@{ C = $c; M = $m; D = $d; P = $p; T = [double]$c.Timestamp_Sys100NS }
}
$S1 = Snap; Start-Sleep -Seconds 3; $S2 = Snap
$dT = $S2.T - $S1.T; if ($dT -le 0) { $dT = 1 }
$CpuBusy = [math]::Round([math]::Max(0, [math]::Min(100, 100 * (1 - ([double]$S2.C.PercentProcessorTime - [double]$S1.C.PercentProcessorTime) / $dT))))
$procCpu = @{}
foreach ($k in $S2.P.Keys) {
    $b = $S2.P[$k]; $base = 0; if ($S1.P.ContainsKey($k)) { $base = $S1.P[$k][1] }
    $d = ($b[1] - $base) / $dT * 100 / $Cores
    if ($d -gt 0) { $procCpu[$b[0]] = [double]$procCpu[$b[0]] + $d }
}
$TopCpu = @($procCpu.GetEnumerator() | Sort-Object Value -Descending | Where-Object { $_.Value -ge 1 } | Select-Object -First 5)
$TopCpuH = ($TopCpu | ForEach-Object { '{0} {1:0}%' -f $_.Key, $_.Value }) -join ', '
$freqM = [double]$S2.M.Frequency_PerfTime; $dTm = ([double]$S2.M.Timestamp_PerfTime - [double]$S1.M.Timestamp_PerfTime) / [math]::Max(1, $freqM)
$PagesIn = 0; if ($dTm -gt 0) { $PagesIn = [math]::Round(([double]$S2.M.PagesInputPersec - [double]$S1.M.PagesInputPersec) / $dTm) }
$freqD = [double]$S2.D.Frequency_PerfTime; $dTd = ([double]$S2.D.Timestamp_PerfTime - [double]$S1.D.Timestamp_PerfTime) / [math]::Max(1, $freqD)
$dBase = [double]$S2.D.AvgDisksecPerTransfer_Base - [double]$S1.D.AvgDisksecPerTransfer_Base
$DiskMs = 0; $Iops = 0
if ($dBase -gt 0 -and $freqD -gt 0) { $DiskMs = [math]::Round((([double]$S2.D.AvgDisksecPerTransfer - [double]$S1.D.AvgDisksecPerTransfer) / $freqD) / $dBase * 1000, 1) }
if ($dTd -gt 0) { $Iops = [math]::Round($dBase / $dTd) }
$Queue = (Get-CimInstance Win32_PerfFormattedData_PerfOS_System).ProcessorQueueLength

# ================================================================== DISKS
Say (L '• диски: место, здоровье (SMART), ошибки, скорость' '• disks: space, health (SMART), errors, speed')
Sec 'Disks: volumes'
$vols = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')
Tech ($vols | Select-Object DeviceID, VolumeName, FileSystem, @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } }, @{n = 'FreeGB'; e = { [math]::Round($_.FreeSpace / 1GB, 1) } } | Format-Table -AutoSize)
$maxPct = 0; $maxVol = ''; $maxFree = 0
foreach ($v in $vols) {
    if (-not $v.Size -or $v.Size -le 0) { continue }
    $free = [double]$v.FreeSpace; $size = [double]$v.Size; $pct = [math]::Round(100 - $free / $size * 100)
    if ($pct -gt $maxPct) { $maxPct = $pct; $maxVol = $v.DeviceID; $maxFree = $free }
    $isSys = ($v.DeviceID -eq $env:SystemDrive)
    $sev = 0
    if ($size -lt 3GB) { if ($pct -ge 97) { $sev = 2 } elseif ($pct -ge 90) { $sev = 1 } }
    elseif ($free -lt 2GB -or $pct -ge 98 -or ($pct -ge 95 -and $free -lt 20GB)) { $sev = 2 }
    elseif (($pct -ge 90 -and $free -lt 50GB) -or ($pct -ge 85 -and $free -lt 5GB) -or ($isSys -and $free -lt 10GB -and $size -ge 40GB)) { $sev = 1 }
    if ($sev -eq 0) { continue }
    $sc = if ($sev -eq 2) { 90 } else { 56 }; if ($isSys) { $sc += 4 }
    $sysWhy = if ($isSys) { L ' На системном диске Windows не может поставить обновления, растёт файл подкачки - система начинает тормозить и сбоить.' ' On the system drive Windows cannot install updates or grow the page file - the system slows down and misbehaves.' } else { '' }
    Add-F $sev 'disk' $sc 'h' (L "Диск $($v.DeviceID) почти заполнен: занято $pct%, свободно $(Fmt-Bytes $free)" "Drive $($v.DeviceID) is almost full: $pct% used, $(Fmt-Bytes $free) free") `
        ((L 'Когда место заканчивается, программы и базы данных не могут записывать данные: появляются ошибки, падают службы, не пишутся логи и бэкапы.' 'When a drive runs out of space, programs and databases cannot write data: errors appear, services crash, logs and backups stop.') + $sysWhy) `
        (L "Посмотрите, что занимает место: Параметры → Система → Память (или бесплатная программа WinDirStat/TreeSize)
Удалите ненужное: старые бэкапы, архивы, большие логи; очистите корзину и временные файлы (cleanmgr - «Очистка диска»)
Если удалять нечего - увеличьте диск у хостера или перенесите данные на другой диск" "Find what takes the space: Settings → System → Storage (or the free WinDirStat/TreeSize)
Delete what you do not need: old backups, archives, big logs; empty the Recycle Bin and temp files (cleanmgr - Disk Cleanup)
If nothing can be deleted, enlarge the drive at your provider or move data to another drive") `
        ("{0} {1} size {2} free {3} ({4}% used)" -f $v.DeviceID, $v.FileSystem, (Fmt-Bytes $size), (Fmt-Bytes $free), $pct)
}
$OK['disk'] = L "занято не больше $maxPct% (самый заполненный: $maxVol, свободно $(Fmt-Bytes $maxFree))" "at most $maxPct% used (fullest: $maxVol, $(Fmt-Bytes $maxFree) free)"

# volume health (needs the Storage module, Windows 8 / Server 2012+)
$gv = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' })
$badVol = @($gv | Where-Object { $_.HealthStatus -and "$($_.HealthStatus)" -notmatch '^(Healthy|0)$' })
if ($badVol.Count -gt 0) {
    $bl = ($badVol | ForEach-Object { "$($_.DriveLetter): $($_.HealthStatus)" }) -join ', '
    Add-F 2 'disk' 90 'h' (L "Файловая система требует проверки: $bl" "A file system needs repair: $bl") `
        (L 'Windows обнаружила повреждения файловой системы. Возможны ошибки при чтении файлов и сбои программ.' 'Windows found file system damage. File read errors and program failures are possible.') `
        (L "Сделайте копию важных данных
Запустите проверку диска в окне администратора: chkdsk $($badVol[0].DriveLetter): /scan (это уже действие - решайте сами или поручите специалисту)
Проверьте здоровье диска (пункт SMART в этом отчёте)" "Back up important data
Run a disk check in an admin window: chkdsk $($badVol[0].DriveLetter): /scan (this is an action - your call, or ask an admin)
Check the disk health (the SMART item in this report)") $bl
}

# physical disks: health + reliability counters (SMART-like)
Sec 'Disks: physical / SMART'
$pd = @(Get-PhysicalDisk)
Tech ($pd | Select-Object DeviceId, FriendlyName, MediaType, BusType, HealthStatus, OperationalStatus, @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } } | Format-Table -AutoSize)
$smartOk = 0
foreach ($d in $pd) {
    $name = "$($d.FriendlyName)".Trim(); $probs = @(); $sev = 0; $sc = 0
    $hs = "$($d.HealthStatus)"
    if ($hs -match 'Unhealthy') { $sev = 2; $sc = 98; $probs += (L 'Windows считает диск неисправным (Unhealthy)' 'Windows marks the disk Unhealthy') }
    elseif ($hs -match 'Warning') { $sev = 2; $sc = 95; $probs += (L 'Windows предупреждает о скором отказе диска (Warning)' 'Windows warns the disk may fail soon (Warning)') }
    $rc = $null; if ($IsAdmin) { $rc = $d | Get-StorageReliabilityCounter }
    if ($rc) {
        Tech ($rc | Select-Object @{n = 'Disk'; e = { $name } }, Temperature, TemperatureMax, Wear, ReadErrorsUncorrected, WriteErrorsUncorrected, ReadErrorsTotal, PowerOnHours | Format-List)
        $ue = [int64]$rc.ReadErrorsUncorrected + [int64]$rc.WriteErrorsUncorrected
        if ($ue -gt 0) { $sev = 2; $sc = [math]::Max($sc, 96); $probs += (L "неисправимых ошибок чтения/записи: $ue" "$ue uncorrectable read/write errors") }
        if ($rc.Wear -ge 100) { $sev = 2; $sc = [math]::Max($sc, 88); $probs += (L "ресурс SSD исчерпан: $($rc.Wear)%" "SSD endurance used up: $($rc.Wear)%") }
        elseif ($rc.Wear -ge 90) { $sev = [math]::Max($sev, 1); $sc = [math]::Max($sc, 60); $probs += (L "ресурс SSD израсходован на $($rc.Wear)%" "SSD endurance $($rc.Wear)% used") }
        $t = [int]$rc.Temperature; $tm = [int]$rc.TemperatureMax
        if ($t -gt 0 -and $t -lt 120) {
            $lim = 70; if ($d.MediaType -eq 'HDD') { $lim = 55 }; if ($tm -gt 40 -and $tm -lt 120) { $lim = $tm }
            if ($t -ge $lim + 10) { $sev = 2; $sc = [math]::Max($sc, 86); $probs += (L "температура $t°C (критическая)" "temperature $t°C (critical)") }
            elseif ($t -ge $lim) { $sev = [math]::Max($sev, 1); $sc = [math]::Max($sc, 55); $probs += (L "температура $t°C (высокая)" "temperature $t°C (high)") }
        }
    }
    if ($sev -eq 0) { $smartOk++; continue }
    $ev = "{0}: Health={1} Op={2} Media={3} Bus={4}" -f $name, $hs, "$($d.OperationalStatus)", $d.MediaType, $d.BusType
    if ($sev -eq 2) {
        Add-F 2 'disk' $sc 'h' (L "Диск «$name» неисправен или отказывает: $($probs -join '; ')" "Disk `"$name`" is failing: $($probs -join '; ')") `
            (L 'Сам диск сообщает о проблемах. Такой диск может отказать в любой момент, а часть данных уже может не читаться.' 'The disk itself reports problems. It can fail at any moment, and some data may already be unreadable.') `
            (L "Немедленно сделайте копию важных данных на другой диск или сервер
Попросите хостера/дата-центр заменить диск («disk failing: $name»), приложите этот отчёт
Если диск в RAID или Storage Spaces - после замены дождитесь окончания восстановления" "Back up important data to another disk/server immediately
Ask your provider / data center to replace the disk (`"disk failing: $name`") and attach this report
If the disk is in a RAID or Storage Spaces, wait for the rebuild to finish after the replacement") $ev
    } else {
        Add-F 1 'disk' $sc 'h' (L "Диск «$name» изнашивается: $($probs -join '; ')" "Disk `"$name`" shows wear: $($probs -join '; ')") `
            (L 'Диск работает, но есть признаки износа или перегрева. Если значения растут - диск скоро откажет.' 'The disk works, but shows wear or heat. If the numbers grow, it will fail soon.') `
            (L "Держите свежий бэкап важных данных
Повторите проверку через неделю; если значения выросли - меняйте диск
Высокая температура - попросите дата-центр проверить охлаждение" "Keep a fresh backup of important data
Re-run the check in a week; if the numbers grew, replace the disk
High temperature - ask the data center to check cooling") $ev
    }
}
if ($IsAdmin) {
    $fp = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus | Where-Object { $_.PredictFailure })
    if ($fp.Count -gt 0) {
        Add-F 2 'disk' 98 'h' (L "SMART предсказывает отказ диска ($($fp.Count) шт.)" "SMART predicts a disk failure ($($fp.Count) disk(s))") `
            (L 'Встроенная самодиагностика диска (SMART) сообщает, что диск скоро откажет.' 'The disk self-diagnostics (SMART) report an imminent failure.') `
            (L "Немедленно сделайте копию важных данных
Попросите хостера/дата-центр заменить диск, приложите отчёт" "Back up important data immediately
Ask your provider / data center to replace the disk and attach this report") (($fp | ForEach-Object { $_.InstanceName }) -join "`n")
    }
    $vd = @(Get-VirtualDisk | Where-Object { "$($_.HealthStatus)" -notmatch '^(Healthy|0)$' })
    if ($vd.Count -gt 0) {
        Add-F 2 'disk' 96 'h' (L "Массив Storage Spaces деградировал: $(($vd | ForEach-Object { "$($_.FriendlyName) ($($_.HealthStatus))" }) -join ', ')" "A Storage Spaces virtual disk is degraded: $(($vd | ForEach-Object { "$($_.FriendlyName) ($($_.HealthStatus))" }) -join ', ')") `
            (L 'Один из дисков массива отказал. Данные пока целы, но запаса больше нет.' 'A disk in the array failed. Data is intact, but there is no redundancy left.') `
            (L "Сделайте свежий бэкап
Замените сбойный диск и дождитесь восстановления (Get-StorageJob показывает прогресс)" "Make a fresh backup
Replace the failed disk and wait for the repair (Get-StorageJob shows progress)") ''
    }
}
if ($IsVM) {
    Note (L 'Сервер виртуальный: здоровье физических дисков и температуру контролирует хостер - это нормально.' 'The server is virtual: physical disk health and temperatures are the provider''s job - this is normal.')
    $OK['disk'] += (L '; SMART не нужен (VPS)' '; SMART n/a (virtual)')
} elseif ($IsAdmin -and $smartOk -gt 0) { $OK['disk'] += (L "; дисков без замечаний: $smartOk" "; $smartOk disk(s) fine") }

# disk / storage / NTFS errors in the System log
$diskEv = @(Get-Ev @{ LogName = 'System'; Id = 7, 11, 15, 51, 129, 153, 157; StartTime = $Since7 } | Where-Object { $_.ProviderName -match '^(disk|storahci|stornvme|storvsc|iaStor|nvme|LSI_|megasas|percsas|HpCISSs|arcsas|mpt3sas|SmartPqi|vhdmp|stornvm|amdsata|amd_sata|vioscsi|viostor)' })
$hardDisk = @($diskEv | Where-Object { $_.Id -in 7, 11, 15, 51 })
if ($hardDisk.Count -gt 0) {
    Add-F 2 'disk' 92 'h' (L "Диск выдаёт ошибки чтения/записи: $($hardDisk.Count) событий за 7 дней" "The disk reports read/write errors: $($hardDisk.Count) events in 7 days") `
        (L 'Windows не смогла прочитать или записать данные (bad block / ошибка контроллера). Частый признак умирающего диска; на виртуальном сервере - проблемы хранилища у хостера.' 'Windows failed to read or write data (bad block / controller error). A typical sign of a dying disk; on a virtual server - provider storage trouble.') `
        (L "Срочно сделайте копию важных данных
Сообщите хостеру/дата-центру: «disk errors (Event ID 7/11/51)», приложите отчёт
Не запускайте тяжёлые операции на этом диске до проверки" "Back up important data right away
Tell your provider / data center: `"disk errors (Event ID 7/11/51)`" and attach this report
Avoid heavy operations on this disk until it is checked") (Ev-Lines $hardDisk)
} elseif ($diskEv.Count -ge 3) {
    Add-F 1 'disk' 58 'm' (L "Диск/контроллер не отвечал вовремя: $($diskEv.Count) сбросов или повторов за 7 дней" "Disk/controller timeouts: $($diskEv.Count) resets or retries in 7 days") `
        (L 'Диск переставал отвечать, и Windows повторяла запросы (события 129/153). В эти моменты сервер «подвисает». Причины: перегруженное хранилище хостера, драйвер, кабель или начало отказа диска.' 'The disk stopped responding and Windows retried (events 129/153). The server freezes at those moments. Causes: overloaded provider storage, a driver, a cable or an early disk failure.') `
        (L "Сообщите хостеру: «storage resets/retries (Event 129/153)»
Обновите драйвер дискового контроллера
Проверьте пункт про здоровье дисков в этом отчёте" "Tell your provider: `"storage resets/retries (Event 129/153)`"
Update the storage controller driver
Check the disk health item in this report") (Ev-Lines $diskEv)
}
$ntfs = @(Get-Ev @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Ntfs', 'Ntfs'; Level = 1, 2, 3; StartTime = $Since })
$ntfsBad = @($ntfs | Where-Object { $_.Id -in 55, 98, 137, 140, 50, 57 })
if ($ntfsBad.Count -gt 0) {
    $sev = 1; $sc = 60; if (@($ntfsBad | Where-Object { $_.Id -in 55, 98 }).Count -gt 0) { $sev = 2; $sc = 91 }
    Add-F $sev 'disk' $sc 'h' (L "Ошибки файловой системы NTFS: $($ntfsBad.Count) за $Days дн." "NTFS file system errors: $($ntfsBad.Count) in $Days days") `
        (L 'Файловая система повреждена или не смогла записать данные. Возможны сбои программ и потеря файлов.' 'The file system is damaged or failed to write data. Program failures and file loss are possible.') `
        (L "Сделайте свежую копию важных данных
Запланируйте проверку: chkdsk <диск>: /scan в окне администратора (это действие - решайте сами или поручите специалисту)
Проверьте здоровье дисков (пункт SMART)" "Make a fresh backup of important data
Schedule a check: chkdsk <drive>: /scan in an admin window (an action - your call, or ask an admin)
Check the disk health (SMART item)") (Ev-Lines $ntfsBad)
}
# disk latency measured in the sampling window
if ($Iops -ge 20 -and $DiskMs -ge 50) {
    $sev = 1; $sc = 50; if ($DiskMs -ge 200) { $sev = 2; $sc = 78 }
    Add-F $sev 'disk' $sc 'm' (L "Диск отвечает медленно: $DiskMs мс на операцию при $Iops операциях/с" "The disk is slow: $DiskMs ms per operation at $Iops IOPS") `
        (L 'Нормально - единицы миллисекунд для SSD и до 20 мс для HDD. Когда диск не успевает, тормозит всё: открытие программ, базы данных, сайты.' 'Normal is a few ms for SSD and up to 20 ms for HDD. When the disk cannot keep up, everything slows down: programs, databases, websites.') `
        (L "Откройте Диспетчер задач → Производительность → Диск и посмотрите, какая программа нагружает диск (вкладка «Монитор ресурсов» → Диск)
Перенесите тяжёлые задачи (бэкапы, антивирусное сканирование, индексацию) на ночь
Если так постоянно - нужен SSD/NVMe или более быстрый тариф" "Open Task Manager → Performance → Disk and see which program loads the disk (Resource Monitor → Disk)
Move heavy jobs (backups, antivirus scans, indexing) to the night
If it is permanent, you need SSD/NVMe or a faster plan") "avg latency $DiskMs ms, $Iops IOPS (3 s sample, all physical disks)"
}

# ================================================================== MEMORY
Say (L '• память: свободная, файл подкачки, нехватка памяти' '• memory: free RAM, page file, low-memory events')
Sec 'Memory'
$memT = [double]$os.TotalVisibleMemorySize * 1KB; $memA = [double]$os.FreePhysicalMemory * 1KB
$commitT = [double]$os.TotalVirtualMemorySize * 1KB; $commitF = [double]$os.FreeVirtualMemory * 1KB
$AP = if ($memT -gt 0) { [math]::Round($memA / $memT * 100) } else { 0 }
$CP = if ($commitT -gt 0) { [math]::Round(100 - $commitF / $commitT * 100) } else { 0 }
$procs = @(Get-Process)
$TopMem = @($procs | Group-Object ProcessName | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Bytes = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum; Count = $_.Count } } | Sort-Object Bytes -Descending | Select-Object -First 5)
$TopMemH = ($TopMem | ForEach-Object { if ($_.Count -gt 1) { '{0} {1} ({2} {3})' -f $_.Name, (Fmt-Bytes $_.Bytes), $_.Count, (L 'проц.' 'procs') } else { '{0} {1}' -f $_.Name, (Fmt-Bytes $_.Bytes) } }) -join ', '
Tech ("RAM available {0} of {1} ({2}%); commit {3}% of {4}; hard page-ins {5}/s" -f (Fmt-Bytes $memA), (Fmt-Bytes $memT), $AP, $CP, (Fmt-Bytes $commitT), $PagesIn)
Tech (Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage | Format-Table -AutoSize)
Tech ("Top memory: $TopMemH")
$lowMem = @(Get-Ev @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'; Id = 2004; StartTime = $Since })
if ($lowMem.Count -gt 0) {
    $who = (@($lowMem | ForEach-Object { [regex]::Matches("$($_.Message)", '([\w\.\-]+\.exe)') | Select-Object -First 3 | ForEach-Object { $_.Groups[1].Value } }) | Group-Object | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object { $_.Name }) -join ', '
    $recent = @($lowMem | Where-Object { $_.TimeCreated -ge $Since7 }).Count
    $sev = 1; $sc = 62; if ($recent -gt 0 -or $lowMem.Count -ge 3) { $sev = 2; $sc = 88 }
    Add-F $sev 'mem' $sc 'h' (L "Windows не хватало памяти: $(Raz $lowMem.Count) за $Days дн., из них за 7 дней - $recent" "Windows ran low on memory: $($lowMem.Count) time(s) in $Days days, $recent in the last 7 days") `
        (L "Когда память кончается, программы падают с ошибками, а Windows сильно тормозит. Больше всего памяти тогда занимали: $who." "When memory runs out, programs crash with errors and Windows slows down badly. The biggest consumers were: $who.") `
        (L "Посмотрите, кто ест память сейчас: $TopMemH
Ограничьте аппетит «прожорливой» программы (например, максимум памяти для SQL Server) или найдите утечку памяти (растёт ли потребление со временем)
Если нагрузка выросла законно - добавьте оперативной памяти (тариф выше) или увеличьте файл подкачки" "See who uses memory now: $TopMemH
Limit the hungry program (for example, max server memory for SQL Server) or look for a leak (does usage grow over time?)
If the load legitimately grew, add RAM (a bigger plan) or enlarge the page file") (Ev-Lines $lowMem 4)
}
if (($AP -lt 5 -and $memA -lt 2GB) -or $CP -ge 95) {
    Add-F 2 'mem' 84 'h' (L "Память почти закончилась: доступно $(Fmt-Bytes $memA) из $(Fmt-Bytes $memT) ($AP%), выделено $CP% от предела" "Memory is almost exhausted: $(Fmt-Bytes $memA) of $(Fmt-Bytes $memT) available ($AP%), commit at $CP% of the limit") `
        (L 'Ещё немного - и программы начнут падать с ошибкой «недостаточно памяти», а Windows станет очень медленной.' 'A bit more and programs will crash with "out of memory" errors and Windows will crawl.') `
        (L "Посмотрите, кто ест память: $TopMemH
Перезапустите или ограничьте самую «прожорливую» программу
Добавьте RAM или увеличьте файл подкачки" "See who uses memory: $TopMemH
Restart or limit the hungriest program
Add RAM or enlarge the page file") "available $(Fmt-Bytes $memA) / $(Fmt-Bytes $memT); commit $CP%; page-ins $PagesIn/s"
} elseif ($PagesIn -ge 1000 -and $AP -lt 15) {
    Add-F 2 'mem' 85 'h' (L "Windows «задыхается»: памяти мало, и она постоянно читает данные из файла подкачки ($PagesIn стр./с)" "Windows is thrashing: memory is short and it keeps reading from the page file ($PagesIn pages/s)") `
        (L 'Оперативной памяти не хватает, поэтому система всё время подгружает данные с диска. Всё работает в разы медленнее.' 'There is not enough RAM, so the system keeps loading data from disk. Everything is many times slower.') `
        (L "Посмотрите, кто ест память: $TopMemH
Закройте/ограничьте лишние программы
Добавьте оперативной памяти" "See who uses memory: $TopMemH
Close/limit unneeded programs
Add RAM") "page-ins $PagesIn/s; available $AP%"
} elseif (($AP -lt 10 -and $memA -lt 4GB) -or $CP -ge 90) {
    Add-F 1 'mem' 52 'm' (L "Памяти впритык: доступно $(Fmt-Bytes $memA) ($AP%), выделено $CP% от предела" "Memory is tight: $(Fmt-Bytes $memA) available ($AP%), commit at $CP%") `
        (L 'Сейчас всё работает, но запаса почти нет: при всплеске нагрузки начнутся тормоза или ошибки.' 'Everything works now, but there is little headroom: a load spike will cause slowdowns or errors.') `
        (L "Посмотрите, кто ест память: $TopMemH
Уменьшите аппетит программ или добавьте RAM" "See who uses memory: $TopMemH
Reduce programs' appetite or add RAM") "available $AP%, commit $CP%"
}
$OK['mem'] = L "доступно $(Fmt-Bytes $memA) из $(Fmt-Bytes $memT) ($AP%), выделено $CP% от предела, нехватки памяти за $Days дн. не было" "$(Fmt-Bytes $memA) of $(Fmt-Bytes $memT) available ($AP%), commit $CP% of the limit, no low-memory events in $Days days"

# ================================================================== CPU / TEMPERATURE / HARDWARE ERRORS
Say (L '• процессор: нагрузка, температура, аппаратные ошибки WHEA' '• CPU: load, temperature, WHEA hardware errors')
Sec 'CPU'
Tech ("CPU busy {0}% over 3 s; processor queue {1}; logical CPUs {2}; top: {3}" -f $CpuBusy, $Queue, $Cores, $TopCpuH)
Tech ($cpus | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, CurrentClockSpeed, MaxClockSpeed, LoadPercentage | Format-List)
if ($CpuBusy -ge 95 -and $Queue -ge 2 * $Cores) { $sev = 2; $sc = 80 } elseif ($CpuBusy -ge 85) { $sev = 1; $sc = 46 } else { $sev = 0 }
if ($sev -gt 0) {
    Add-F $sev 'cpu' $sc 'm' (L "Процессор перегружен: занят на $CpuBusy%" "The CPU is overloaded: $CpuBusy% busy") `
        (L "Задач больше, чем процессор успевает обработать, поэтому всё отвечает медленнее. Больше всего процессор занимают: $TopCpuH." "There is more work than the CPU can handle, so everything responds slower. Top CPU users: $TopCpuH.") `
        (L "Проверьте программы из списка: $TopCpuH. Если среди них незнакомая - выясните, что это
Если это антивирус (MsMpEng) или обновления (TiWorker, TrustedInstaller) - обычно это временно, проверьте ещё раз через час
Если такая нагрузка - норма для вашей работы, нужен тариф с большим числом ядер" "Check the programs in the list: $TopCpuH. If one is unfamiliar, find out what it is
If it is the antivirus (MsMpEng) or updates (TiWorker, TrustedInstaller), it is usually temporary - check again in an hour
If this load is normal for your work, you need a plan with more cores") "busy $CpuBusy% (3 s), queue $Queue, cores $Cores; top: $TopCpuH"
}
$tz = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature)
$TempC = $null
if ($tz.Count -gt 0) {
    $vals = @($tz | ForEach-Object { [math]::Round($_.CurrentTemperature / 10 - 273.15) } | Where-Object { $_ -gt 5 -and $_ -lt 120 })
    if ($vals.Count -gt 0) { $TempC = ($vals | Measure-Object -Maximum).Maximum; Tech ("ACPI thermal zones (°C): " + ($vals -join ', ')) }
}
if ($null -ne $TempC -and $TempC -ge 85) {
    $sev = 1; $sc = 58; if ($TempC -ge 95) { $sev = 2; $sc = 89 }
    Add-F $sev 'cpu' $sc 'm' (L "Перегрев: датчик показывает $TempC°C" "Overheating: a sensor reads $TempC°C") `
        (L 'При перегреве процессор сбрасывает частоту (всё тормозит), а при критической температуре компьютер может внезапно выключиться. Обычно виноваты пыль, вентилятор или термопаста.' 'When overheating, the CPU slows down, and at a critical temperature the computer may suddenly power off. Usual causes: dust, a fan or thermal paste.') `
        (L "Сообщите хостеру/дата-центру: «перегрев, проверьте охлаждение»
Если компьютер ваш - почистите от пыли, проверьте вентиляторы, замените термопасту" "Tell your provider / data center: `"overheating, please check cooling`"
If the machine is yours - clean the dust, check the fans, replace thermal paste") "ACPI thermal zone max $TempC°C"
}
if (-not $IsVM -and $null -eq $TempC) { Note (L 'Датчик температуры через Windows недоступен (обычное дело для серверов) - температура не проверена.' 'No temperature sensor is exposed to Windows (common on servers) - temperature was not checked.') }
$thr = @(Get-Ev @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = $Since7 })
if ($thr.Count -gt 0 -and -not $IsVM) {
    Add-F 1 'cpu' 50 'm' (L "Прошивка ограничивала скорость процессора: $(Raz $thr.Count) за 7 дней" "Firmware limited the CPU speed $($thr.Count) time(s) in 7 days") `
        (L 'Процессор работал медленнее обычного по команде BIOS/прошивки - чаще всего из-за перегрева или настроек энергосбережения.' 'The CPU ran slower than normal on firmware request - usually overheating or power-saving settings.') `
        (L "Проверьте охлаждение (вентиляторы, пыль)
В BIOS/схеме электропитания выберите режим «Высокая производительность»" "Check cooling (fans, dust)
Choose the High performance power plan / BIOS profile") (Ev-Lines $thr 3)
}
$plan = (powercfg /getactivescheme 2>$null) -join ' '
Tech ("Power plan: $plan")
if ($plan -match 'a1841308-3541-4fab-bc81-f71556f20b4a') {
    Add-F 1 'cpu' 35 'h' (L 'Включена схема электропитания «Экономия энергии» - процессор работает медленнее' 'The Power saver plan is active - the CPU runs slower') `
        (L 'В режиме экономии Windows занижает частоту процессора. Для сервера это лишнее замедление.' 'In Power saver mode Windows lowers the CPU clock. For a server that is an unnecessary slowdown.') `
        (L "Панель управления → Электропитание → выберите «Сбалансированная» или «Высокая производительность»" "Control Panel → Power Options → choose Balanced or High performance") $plan
}
$whea = @(Get-Ev @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $Since })
if ($whea.Count -gt 0) {
    $fatal = @($whea | Where-Object { $_.Level -le 2 -or $_.Id -in 1, 18, 20, 46 })
    $sev = 1; $sc = 60; if ($fatal.Count -gt 0) { $sev = 2; $sc = 95 }
    Add-F $sev 'cpu' $sc 'h' (L "Аппаратные ошибки WHEA (процессор/память/шина): $($whea.Count) за $Days дн., из них критических - $($fatal.Count)" "WHEA hardware errors (CPU/memory/bus): $($whea.Count) in $Days days, $($fatal.Count) fatal") `
        (L 'WHEA - это сигнал самого «железа» об ошибке процессора, памяти или шины PCIe. Исправленные ошибки - предупреждение, критические - причина синих экранов и перезагрузок.' 'WHEA is the hardware itself reporting a CPU, memory or PCIe error. Corrected ones are a warning; fatal ones cause blue screens and reboots.') `
        (L "Сообщите хостеру/дата-центру: «WHEA hardware errors», приложите отчёт - нужна диагностика железа
Если компьютер ваш - проверьте память (Средство проверки памяти Windows: mdsched), обновите BIOS и драйверы чипсета, проверьте охлаждение
Держите свежий бэкап" "Tell your provider / data center: `"WHEA hardware errors`" and attach this report - hardware diagnostics are needed
If the machine is yours - test RAM (Windows Memory Diagnostic: mdsched), update BIOS and chipset drivers, check cooling
Keep a fresh backup") (Ev-Lines $whea)
}
$cpuOk = L "занят на $CpuBusy% (замер 3 сек.), ядер: $Cores" "$CpuBusy% busy (3 s sample), $Cores logical CPUs"
if ($null -ne $TempC) { $cpuOk += (L ", температура $TempC°C" ", temperature $TempC°C") }
$OK['cpu'] = $cpuOk

# ================================================================== CRASHES / REBOOTS
Say (L '• сбои: синие экраны, внезапные выключения' '• crashes: blue screens, unexpected shutdowns')
Sec 'Crashes / reboots'
$kp = @(Get-Ev @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $Since })
$e6008 = @(Get-Ev @{ LogName = 'System'; Id = 6008; StartTime = $Since })
$bc = @(Get-Ev @{ LogName = 'System'; Id = 1001; StartTime = $Since } | Where-Object { $_.ProviderName -match 'WER-SystemErrorReporting|BugCheck' })
$planned = @(Get-Ev @{ LogName = 'System'; ProviderName = 'User32'; Id = 1074; StartTime = $Since })
Tech ("Kernel-Power 41: {0}; EventLog 6008: {1}; BugCheck 1001: {2}; planned shutdowns (1074): {3}" -f $kp.Count, $e6008.Count, $bc.Count, $planned.Count)
Tech (Ev-Lines ($kp + $e6008 + $bc) 10)
Tech ("Planned restarts (who/why):`n" + (@($planned | Sort-Object TimeCreated -Descending | Select-Object -First 8 | ForEach-Object { '{0}  {1} | {2} | {3}' -f $_.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $_.Properties[0].Value, $_.Properties[2].Value, $_.Properties[4].Value }) -join "`n"))
# blue screens: bugcheck codes from 1001 and from Kernel-Power 41
$codes = @()
foreach ($e in $bc) { $m = [regex]::Match("$($e.Properties[0].Value) $($e.Message)", '0x[0-9a-fA-F]{8}'); if ($m.Success) { $codes += ('0x{0:X}' -f [Convert]::ToUInt32($m.Value.Substring(2), 16)) } }
foreach ($e in $kp) { $c = 0; try { $c = [uint32]$e.Properties[0].Value } catch { }; if ($c -gt 0) { $codes += ('0x{0:X}' -f $c) } }
$dumps = @()
if ($IsAdmin) {
    $dumps = @(Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Since })
    $md = Get-Item "$env:SystemRoot\MEMORY.DMP" -ErrorAction SilentlyContinue; if ($md -and $md.LastWriteTime -ge $Since) { $dumps += $md }
    Tech ("Crash dumps (last $Days days):`n" + (@($dumps | ForEach-Object { '{0}  {1}  {2}' -f $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $_.FullName, (Fmt-Bytes $_.Length) }) -join "`n"))
    $lkr = @(Get-ChildItem "$env:SystemRoot\LiveKernelReports" -Recurse -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Since })
    if ($lkr.Count -gt 0) { Tech ("LiveKernelReports:`n" + (@($lkr | ForEach-Object { '{0}  {1}' -f $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $_.FullName }) -join "`n")) }
}
$codeInfo = @{
    '0xA' = 'IRQL_NOT_LESS_OR_EQUAL|drv'; '0xD1' = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL|drv'; '0x1E' = 'KMODE_EXCEPTION_NOT_HANDLED|drv'; '0x3B' = 'SYSTEM_SERVICE_EXCEPTION|drv'
    '0x7E' = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED|drv'; '0x9F' = 'DRIVER_POWER_STATE_FAILURE|drv'; '0xC2' = 'BAD_POOL_CALLER|drv'; '0x19' = 'BAD_POOL_HEADER|drv'
    '0xC5' = 'DRIVER_CORRUPTED_EXPOOL|drv'; '0x133' = 'DPC_WATCHDOG_VIOLATION|drv'; '0x13A' = 'KERNEL_MODE_HEAP_CORRUPTION|drv'; '0x139' = 'KERNEL_SECURITY_CHECK_FAILURE|drv'
    '0x116' = 'VIDEO_TDR_FAILURE|gpu'; '0x117' = 'VIDEO_TDR_TIMEOUT_DETECTED|gpu'; '0x1A' = 'MEMORY_MANAGEMENT|ram'; '0x50' = 'PAGE_FAULT_IN_NONPAGED_AREA|ram'
    '0x109' = 'CRITICAL_STRUCTURE_CORRUPTION|ram'; '0x7F' = 'UNEXPECTED_KERNEL_MODE_TRAP|hw'; '0x124' = 'WHEA_UNCORRECTABLE_ERROR|hw'; '0x9C' = 'MACHINE_CHECK_EXCEPTION|hw'
    '0x101' = 'CLOCK_WATCHDOG_TIMEOUT|hw'; '0x7A' = 'KERNEL_DATA_INPAGE_ERROR|disk'; '0x77' = 'KERNEL_STACK_INPAGE_ERROR|disk'; '0xF4' = 'CRITICAL_OBJECT_TERMINATION|disk'
    '0x154' = 'UNEXPECTED_STORE_EXCEPTION|disk'; '0xEF' = 'CRITICAL_PROCESS_DIED|sys'; '0xE2' = 'MANUALLY_INITIATED_CRASH|manual'; '0x9E' = 'USER_MODE_HEALTH_MONITOR|sys'
}
if ($codes.Count -gt 0 -or $dumps.Count -gt 0) {
    $uc = @($codes | Select-Object -Unique)
    $names = @($uc | ForEach-Object { $i = $codeInfo[$_]; if ($i) { "$_ $($i.Split('|')[0])" } else { $_ } })
    $cats = @($uc | ForEach-Object { $i = $codeInfo[$_]; if ($i) { $i.Split('|')[1] } } | Select-Object -Unique)
    $hint = switch ($cats | Select-Object -First 1) {
        'drv' { L 'Такой код почти всегда означает сбой ДРАЙВЕРА (сетевой карты, диска, видеокарты, антивируса).' 'This code almost always means a faulty DRIVER (network, storage, video, antivirus).' }
        'gpu' { L 'Код указывает на видеодрайвер или видеокарту.' 'The code points to the video driver or the GPU.' }
        'ram' { L 'Код часто означает неисправную оперативную память (реже - драйвер).' 'The code often means faulty RAM (less often a driver).' }
        'hw' { L 'Код означает аппаратную ошибку: процессор, память, перегрев или питание.' 'The code means a hardware error: CPU, memory, overheating or power.' }
        'disk' { L 'Код означает, что Windows не смогла прочитать данные с диска - проверьте диск.' 'The code means Windows could not read data from the disk - check the disk.' }
        'manual' { L 'Синий экран вызван вручную (кнопка NMI или команда хостера) - обычно при зависании.' 'The crash was triggered manually (NMI button or provider command) - usually after a hang.' }
        default { L 'Код ошибки указан ниже; по нему специалист найдёт причину.' 'The stop code is listed below; an admin can find the cause from it.' }
    }
    $when = @(($bc + @($kp | Where-Object { [uint32]$_.Properties[0].Value -gt 0 })) | Sort-Object TimeCreated -Descending | Select-Object -First 3 | ForEach-Object { Fmt-Date $_.TimeCreated })
    if ($when.Count -eq 0) { $when = @($dumps | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object { Fmt-Date $_.LastWriteTime }) }
    $nb = [math]::Max(@($bc).Count, $dumps.Count); if ($nb -lt 1) { $nb = $uc.Count }
    $codesTxt = if ($names.Count -gt 0) { $names -join ', ' } else { L 'код не записан' 'code not recorded' }
    Add-F 2 'crash' 93 'h' (L "Синие экраны (BSOD): $nb за $Days дн. - $codesTxt" "Blue screens (BSOD): $nb in $Days days - $codesTxt") `
        ((L 'Синий экран - аварийная остановка Windows с перезагрузкой. ' 'A blue screen is an emergency stop of Windows followed by a reboot. ') + $hint + (L " Последние: $($when -join ', ')." " Latest: $($when -join ', ').")) `
        (L "Обновите драйверы (особенно сетевой карты, дискового контроллера, видеокарты) и Windows; если перед сбоями что-то устанавливали - откатите это
Отправьте специалисту этот отчёт и файлы из C:\Windows\Minidump - по ним видно, какой драйвер виноват (анализ в WinDbg или BlueScreenView)
Если код «железный» (память/WHEA) или сбои повторяются - проверьте память (mdsched) и попросите хостера проверить оборудование" "Update drivers (especially network, storage controller, video) and Windows; if something was installed before the crashes, roll it back
Send this report and the files from C:\Windows\Minidump to an admin - they show which driver is at fault (WinDbg or BlueScreenView)
If the code is hardware-related (memory/WHEA) or crashes repeat - test RAM (mdsched) and ask your provider to check the hardware") `
        ((Ev-Lines ($bc + $kp) 6) + "`n" + (@($dumps | Select-Object -First 5 | ForEach-Object { "dump: $($_.FullName) $($_.LastWriteTime)" }) -join "`n"))
}
# unexpected shutdowns (41 / 6008 within 15 min of each other = one incident)
$inc = @(); foreach ($e in (@($kp + $e6008) | Sort-Object TimeCreated)) { if ($inc.Count -eq 0 -or ($e.TimeCreated - $inc[-1]).TotalMinutes -gt 15) { $inc += $e.TimeCreated } }
if ($inc.Count -gt 0) {
    $inc7 = @($inc | Where-Object { $_ -ge $Since7 }).Count
    $sev = 1; $sc = 55; if ($inc7 -ge 1) { $sc = 66 }; if ($inc.Count -ge 2) { $sev = 2; $sc = 84 }
    $wl = (@($inc | Sort-Object -Descending | Select-Object -First 5 | ForEach-Object { Fmt-Date $_ })) -join ', '
    Add-F $sev 'crash' $sc 'm' (L "Windows выключалась аварийно (без нормального завершения работы): $(Raz $inc.Count) за $Days дн. - $wl" "Windows shut down unexpectedly (no clean shutdown) $($inc.Count) time(s) in $Days days - $wl") `
        (L 'Компьютер выключился или перезагрузился без нормального завершения работы: пропало питание, хостер сделал принудительный reset, система зависла или случился синий экран. Время - момент загрузки после сбоя.' 'The machine powered off or restarted without a clean shutdown: power loss, a forced reset by the provider, a freeze or a blue screen. The time is the boot after the failure.') `
        (L "Спросите хостера, не было ли в это время работ, сбоя питания или перезагрузки по их инициативе
Посмотрите другие пункты отчёта: синие экраны, WHEA, перегрев, ошибки дисков, нехватка памяти
Если сбои повторяются без видимой причины - попросите хостера проверить железо и питание" "Ask your provider whether there was maintenance, a power failure or a reset on their side
Look at other items in this report: blue screens, WHEA, overheating, disk errors, low memory
If failures repeat without a visible cause, ask your provider to check hardware and power") (Ev-Lines ($kp + $e6008) 6)
}
$OK['crash'] = L "внезапных выключений и синих экранов за $Days дн. нет; работает без перезагрузки $(Fmt-Dur $Up)" "no unexpected shutdowns or blue screens in $Days days; up $(Fmt-Dur $Up)"
$logInfo = Get-WinEvent -ListLog System
if ($logInfo -and $logInfo.RecordCount -gt 0) {
    $first = (Get-WinEvent -LogName System -MaxEvents 1 -Oldest).TimeCreated
    if ($first -and $first -gt $Since) {
        Limit (L "Журнал System хранит события только с $(Fmt-Date $first) - более ранние сбои не видны (журнал ограничен размером $(Fmt-Bytes $logInfo.MaximumSizeInBytes))." "The System log only goes back to $(Fmt-Date $first) - earlier failures are invisible (the log is capped at $(Fmt-Bytes $logInfo.MaximumSizeInBytes)).")
    }
}

# ================================================================== SERVICES / PROGRAMS / UPDATES
Say (L '• службы и программы: падения, остановленные службы, обновления, Defender' '• services: crashes, stopped services, updates, Defender')
Sec 'Services / programs'
$IMP = '^(W3SVC|WAS|IISADMIN|MSSQL.*|SQLAgent.*|SQLSERVERAGENT|MySQL.*|MariaDB.*|postgresql.*|Apache.*|nginx|Tomcat.*|WinRM|TermService|Dnscache|Dhcp|DNS|NTDS|LanmanServer|LanmanWorkstation|Netlogon|W32Time|EventLog|RpcSs|Schedule|MSExchange.*|vmms|ClusSvc|sshd|Docker|com\.docker.*|redis.*|MongoDB|memcached|FileZilla.*|ftpsvc|SMTPSVC|IISADMIN)$'
$scm = @(Get-Ev @{ LogName = 'System'; ProviderName = 'Service Control Manager'; Id = 7031, 7034, 7023, 7024; StartTime = $Since7 })
$crashNames = @($scm | Where-Object { $_.Id -in 7031, 7034 } | ForEach-Object { "$($_.Properties[0].Value)" })
$down = @(Get-CimInstance Win32_Service | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and $_.ExitCode -ne 0 -and $_.ExitCode -ne 1077 -and $_.Name -notmatch '^(sppsvc|gupdate|gupdatem|edgeupdate|edgeupdatem|MapsBroker|RemoteRegistry|WbioSrvc|tiledatamodelsvc|CDPSvc|GoogleUpdater.*|MicrosoftEdgeElevationService|BITS|wuauserv|UsoSvc|DoSvc|WaaSMedicSvc|TrustedInstaller|Sense|SysMain|ShellHWDetection|WSearch|OneSyncSvc.*|CDPUserSvc.*|AppReadiness|camsvc|DiagTrack|dmwappushservice|SgrmBroker|uhssvc|NetTcpPortSharing|vds|ScDeviceEnum|stisvc|WpnUserService.*|BrokerInfrastructure)$' })
Tech ("Service crashes (7 days, Event 7031/7034): " + (Top-Names $crashNames 10))
Tech ("Auto-start services that are not running (with an error code):`n" + (@($down | ForEach-Object { '{0} ({1}) state={2} exit={3}' -f $_.Name, $_.DisplayName, $_.State, $_.ExitCode }) -join "`n"))
$impDown = @($down | Where-Object { $_.Name -match $IMP })
$othDown = @($down | Where-Object { $_.Name -notmatch $IMP })
if ($impDown.Count -gt 0) {
    $n1 = $impDown[0].Name
    Add-F 2 'svc' 85 'h' (L "Не работает важная служба: $(($impDown | ForEach-Object { "$($_.DisplayName) ($($_.Name))" }) -join ', ')" "An important service is down: $(($impDown | ForEach-Object { "$($_.DisplayName) ($($_.Name))" }) -join ', ')") `
        (L 'Служба должна запускаться автоматически, но остановилась с ошибкой. Пока она стоит, не работает то, за что она отвечает (сайт, база данных, удалённый доступ...).' 'The service should run automatically but stopped with an error. While it is down, whatever it provides (website, database, remote access...) does not work.') `
        (L "Посмотрите причину: Просмотр событий → Журналы Windows → Система, события от «Service Control Manager» про $n1
Частые причины - кончилось место на диске, неверный пароль учётной записи службы, ошибка в настройках после изменений
Когда причина устранена, запустите службу: services.msc → $n1 → Запустить" "See why: Event Viewer → Windows Logs → System, events from Service Control Manager about $n1
Common causes - a full disk, a wrong service account password, a config error after changes
Once fixed, start it: services.msc → $n1 → Start") (@($impDown | ForEach-Object { '{0} ({1}) exit code {2}' -f $_.Name, $_.DisplayName, $_.ExitCode }) -join "`n")
}
if ($othDown.Count -gt 0) {
    Add-F 1 'svc' 42 'h' (L "Автоматические службы остановлены с ошибкой: $(($othDown | Select-Object -First 5 | ForEach-Object { $_.DisplayName }) -join ', ')" "Auto-start services stopped with an error: $(($othDown | Select-Object -First 5 | ForEach-Object { $_.DisplayName }) -join ', ')") `
        (L 'Эти службы должны работать, но остановились с кодом ошибки. Часто это мелочь, но иногда - важная фоновая работа (бэкап, мониторинг, агент хостера).' 'These services should run but stopped with an error code. Often minor, sometimes important background work (backup, monitoring, provider agent).') `
        (L "Откройте services.msc, найдите службу и посмотрите её состояние и журнал событий
Если служба не нужна - переключите её на «Вручную»; если нужна - исправьте ошибку и запустите" "Open services.msc, find the service and check its status and the event log
If it is not needed, set it to Manual; if it is, fix the error and start it") (@($othDown | ForEach-Object { '{0} ({1}) exit code {2}' -f $_.Name, $_.DisplayName, $_.ExitCode }) -join "`n")
}
if ($crashNames.Count -ge 3) {
    $grp = @($crashNames | Group-Object | Sort-Object Count -Descending)
    $sc = 45; if ($grp[0].Count -ge 20) { $sc = 60 }
    Add-F 1 'svc' $sc 'h' (L "Службы аварийно завершались за 7 дней: $(Top-Names $crashNames)" "Services crashed in the last 7 days: $(Top-Names $crashNames)") `
        (L 'Windows перезапускает упавшую службу, поэтому снаружи она «вроде работает», но в моменты падений её функции недоступны.' 'Windows restarts a crashed service, so it "seems to work", but it is unavailable during the crashes.') `
        (L "Посмотрите причину падений: Просмотр событий → Приложение, ошибки от программы этой службы в те же минуты
Обновите программу службы до свежей версии
Частые причины - нехватка памяти, повреждённые настройки, сбой зависимостей" "See why it crashes: Event Viewer → Application, errors from that program at the same minutes
Update the service's program
Common causes - low memory, corrupted settings, a failing dependency") (Ev-Lines ($scm | Where-Object { $_.Id -in 7031, 7034 }))
}
$appErr = @(Get-Ev @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; Id = 1000, 1002; StartTime = $Since7 })
$appNames = @($appErr | ForEach-Object { "$($_.Properties[0].Value)" })
$memLinked = @($appErr | Where-Object { $t = $_.TimeCreated; @($lowMem | Where-Object { [math]::Abs(($_.TimeCreated - $t).TotalMinutes) -le 10 }).Count -gt 0 }).Count
$linkTxt = ''; $scApp = 38
if ($memLinked -gt 0) { $scApp = 30; $linkTxt = L " $memLinked из них совпали по времени с нехваткой памяти (см. пункт про память) - скорее всего, причина в ней." " $memLinked of them happened at the same time as a low-memory event (see the memory item) - that is the likely cause." }
if ($appErr.Count -ge 3) {
    Add-F 1 'svc' $scApp 'h' (L "Программы падали или зависали за 7 дней: $(Top-Names $appNames)" "Programs crashed or hung in the last 7 days: $(Top-Names $appNames)") `
        ((L 'Программа «вылетала» с ошибкой или переставала отвечать. Если это ваш сайт, бот или база - в эти моменты они не работали.' 'A program crashed or stopped responding. If it is your site, bot or database, it was down at those moments.') + $linkTxt) `
        (L "Обновите эти программы до свежих версий
Посмотрите подробности: Просмотр событий → Журналы Windows → Приложение (события 1000/1002)
Если падают многие программы сразу - проверьте память (mdsched) и диск" "Update these programs to current versions
See details: Event Viewer → Windows Logs → Application (events 1000/1002)
If many programs crash at once - test RAM (mdsched) and the disk") (Ev-Lines $appErr)
} elseif ($appErr.Count -gt 0) { Note (L "Единичные падения программ за 7 дней: $(Top-Names $appNames)." "Isolated program crashes in 7 days: $(Top-Names $appNames).") }
# Windows Update
$wu = @(Get-Ev @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 20; StartTime = $Since })
$wuKb = @($wu | ForEach-Object { $m = [regex]::Match("$($_.Message)", 'KB\d{6,8}'); if ($m.Success) { $m.Value } else { $t = "$($_.Properties[1].Value)".Trim(); if ($t) { $t } else { 'update' } } })
$wuOs = @($wu | Where-Object { "$($_.Message) $($_.Properties[1].Value)" -match 'KB\d{6,8}' })
$wuStore = @($wuKb | Where-Object { $_ -notmatch '^KB\d' -and $_ -ne 'update' } | Select-Object -Unique)
if ($wuStore.Count -gt 0) {
    $stCodes = @($wu | Where-Object { "$($_.Message)" -notmatch 'KB\d{6,8}' } | ForEach-Object { [regex]::Match("$($_.Message)", '0x[0-9A-Fa-f]{8}').Value } | Where-Object { $_ } | Select-Object -Unique) -join ', '
    $busy = ''; if ($stCodes -match '80073D02') { $busy = L ' (0x80073D02 - приложение было запущено во время обновления; обновится, когда его закроют)' ' (0x80073D02 - the app was running during the update; it will update once closed)' }
    Note (L "Не обновляются приложения Microsoft Store: $($wuStore -join ', ') - ошибка $stCodes$busy." "Microsoft Store apps fail to update: $($wuStore -join ', ') - error $stCodes$busy.")
}
$hot = @(Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending)
$lastHf = if ($hot.Count -gt 0) { $hot[0].InstalledOn } else { $null }
Tech ("Windows Update install failures ($Days d): $($wu.Count) $(Top-Names $wuKb); last installed update: $(if ($lastHf) { $lastHf.ToString('yyyy-MM-dd') } else { 'unknown' })")
$wuOsKb = @($wuOs | ForEach-Object { [regex]::Match("$($_.Message) $($_.Properties[1].Value)", 'KB\d{6,8}').Value })
$wuRepeat = @($wuOsKb | Group-Object | Where-Object { $_.Count -ge 2 })
if ($wuRepeat.Count -gt 0 -or $wuOs.Count -ge 3) {
    $wu = $wuOs; $wuKb = $wuOsKb
    $codesWu = @($wu | ForEach-Object { [regex]::Match("$($_.Message)", '0x[0-9A-Fa-f]{8}').Value } | Where-Object { $_ } | Select-Object -Unique) -join ', '
    Add-F 1 'svc' 45 'h' (L "Обновления Windows не устанавливаются: $($wu.Count) неудачных попыток за $Days дн. ($(Top-Names $wuKb 3))" "Windows updates fail to install: $($wu.Count) failed attempts in $Days days ($(Top-Names $wuKb 3))") `
        (L "Windows раз за разом пытается поставить обновление и откатывает его. Это нагружает сервер и может вызывать перезагрузки. Коды ошибок: $codesWu." "Windows keeps trying to install an update and rolls it back. This loads the server and can cause reboots. Error codes: $codesWu.") `
        (L "Проверьте, что на диске C: свободно хотя бы 10-20 ГБ
Перезагрузите сервер в удобное время и попробуйте установить обновление снова
Если не помогает - поищите код ошибки ($codesWu) на сайте Microsoft или запустите средство устранения неполадок Центра обновления" "Make sure drive C: has at least 10-20 GB free
Reboot at a convenient time and retry the update
If that does not help, search the error code ($codesWu) on Microsoft's site or run the Windows Update troubleshooter") (Ev-Lines $wu 4)
}
# pending reboot (registry, read-only)
$pend = @()
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pend += 'CBS' }
if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pend += 'WindowsUpdate' }
if ($pend.Count -gt 0) { Note (L "Windows ждёт перезагрузки, чтобы закончить установку обновлений ($($pend -join ', ')). Работает без перезагрузки $(Fmt-Dur $Up)." "Windows is waiting for a reboot to finish installing updates ($($pend -join ', ')). Up $(Fmt-Dur $Up).") }
# Defender (health of the built-in antivirus: running, signatures fresh, CPU use)
$mp = $null; try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { }
$defTxt = ''
if ($mp) {
    Tech ($mp | Select-Object AMServiceEnabled, AntivirusEnabled, RealTimeProtectionEnabled, AntivirusSignatureAge, AntivirusSignatureLastUpdated, QuickScanAge, FullScanAge | Format-List)
    if ($mp.AntivirusEnabled) { $defTxt = L ", Defender включён (базы: $($mp.AntivirusSignatureAge) дн.)" ", Defender on (signatures $($mp.AntivirusSignatureAge) d old)" } else { $defTxt = L ', Defender выключен' ', Defender off' }
    if ($mp.AntivirusEnabled -and $mp.AntivirusSignatureAge -gt 14 -and $mp.AntivirusSignatureAge -lt 10000) {
        Add-F 1 'svc' 40 'h' (L "Антивирус Defender не обновляет базы уже $($mp.AntivirusSignatureAge) дн." "Defender has not updated its signatures for $($mp.AntivirusSignatureAge) days") `
            (L 'Defender включён, но его базы давно не обновлялись - значит, сломано обновление (нет доступа к серверам Microsoft или служба обновления не работает).' 'Defender is on, but its signatures are old - updating is broken (no access to Microsoft servers or the update service does not work).') `
            (L "Безопасность Windows → Защита от вирусов и угроз → Проверить наличие обновлений
Если не обновляется - проверьте интернет и пункт про обновления Windows в этом отчёте" "Windows Security → Virus & threat protection → Check for updates
If it fails, check the internet and the Windows Update item in this report") "AntivirusSignatureAge=$($mp.AntivirusSignatureAge)"
    }
}
$mpCpu = @($TopCpu | Where-Object { $_.Key -eq 'MsMpEng' -and $_.Value -ge 25 })
if ($mpCpu.Count -gt 0) {
    Add-F 1 'svc' 44 'h' (L "Антивирус Defender сейчас сильно грузит процессор: $([math]::Round($mpCpu[0].Value))%" "Defender is using a lot of CPU right now: $([math]::Round($mpCpu[0].Value))%") `
        (L 'Идёт проверка файлов. На загруженном сервере это заметно замедляет работу сайтов и баз данных.' 'It is scanning files. On a busy server this noticeably slows down sites and databases.') `
        (L "Перенесите плановое сканирование на ночь (Планировщик заданий → Microsoft → Windows → Windows Defender)
Попросите специалиста добавить папки баз данных и логов в исключения - это снижает нагрузку" "Move the scheduled scan to the night (Task Scheduler → Microsoft → Windows → Windows Defender)
Ask an admin to exclude database and log folders - this reduces the load") "MsMpEng $([math]::Round($mpCpu[0].Value))% CPU"
}
$OK['svc'] = (L 'упавших служб нет' 'no failed services') + $(if ($lastHf) { L ", последнее обновление Windows: $(Fmt-Date $lastHf)" ", last Windows update: $(Fmt-Date $lastHf)" } else { '' }) + $defTxt
Tech ($procs | Sort-Object CPU -Descending | Select-Object -First 12 Name, Id, @{n = 'CPU_s'; e = { [math]::Round($_.CPU) } }, @{n = 'WS_MB'; e = { [math]::Round($_.WorkingSet64 / 1MB) } } | Format-Table -AutoSize)

# ================================================================== NETWORK / TIME
Say (L '• сеть и время: шлюз, DNS, интернет, потери, MTU, часы' '• network & time: gateway, DNS, internet, loss, MTU, clock')
Sec 'Network'
Tech (Get-NetIPConfiguration | Select-Object InterfaceAlias, @{n = 'IPv4'; e = { $_.IPv4Address.IPAddress -join ',' } }, @{n = 'Gateway'; e = { $_.IPv4DefaultGateway.NextHop -join ',' } }, @{n = 'DNS'; e = { $_.DNSServer.ServerAddresses -join ',' } } | Format-Table -AutoSize)
function Test-Tcp([string]$h, [int]$p, [int]$ms = 3000) { $c = New-Object System.Net.Sockets.TcpClient; try { $t = $c.ConnectAsync($h, $p); return ($t.Wait($ms) -and $c.Connected) } catch { return $false } finally { $c.Close() } }
function Test-Dns([string]$n) { try { $t = [System.Net.Dns]::GetHostAddressesAsync($n); return ($t.Wait(4000) -and $t.Result.Count -gt 0) } catch { return $false } }
$gw = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Where-Object { $_.NextHop -ne '0.0.0.0' })
$inet = $false; foreach ($h in '1.1.1.1', '8.8.8.8', '77.88.8.8') { if (Test-Tcp $h 443) { $inet = $true; break } }
$dns = $false; foreach ($n in 'google.com', 'cloudflare.com', 'ya.ru') { if (Test-Dns $n) { $dns = $true; break } }
$netOk = $true
if ($gw.Count -eq 0 -and -not $inet) {
    $netOk = $false
    Add-F 2 'net' 88 'h' (L 'Нет маршрута в интернет (не задан основной шлюз)' 'No route to the internet (no default gateway)') `
        (L 'Компьютер не знает, куда отправлять пакеты за пределы своей сети, поэтому снаружи он недоступен и сам ничего не может скачать.' 'The machine does not know where to send packets outside its network, so it is unreachable and cannot download anything.') `
        (L "Проверьте настройки сетевого адаптера (IP, маска, шлюз) и сверьте их с панелью хостера
Если доступ есть только через консоль хостера - исправьте настройки там или обратитесь в поддержку" "Check the network adapter settings (IP, mask, gateway) against your provider's panel
If you only have the provider's console, fix it there or contact support") ''
} elseif (-not $inet) {
    $netOk = $false
    Add-F 2 'net' 86 'm' (L 'Нет выхода в интернет: не открываются соединения к 1.1.1.1, 8.8.8.8, 77.88.8.8' 'No internet access: connections to 1.1.1.1, 8.8.8.8, 77.88.8.8 fail') `
        (L 'Компьютер не может подключиться наружу. Причина - файрвол, блокировка у хостера или сбой сети. Если сервер намеренно изолирован - это нормально.' 'The machine cannot connect out. Causes: a firewall, a block at the provider or a network fault. If the server is isolated on purpose, this is fine.') `
        (L "Проверьте правила брандмауэра для исходящих соединений
Проверьте, не заблокирован ли сервер хостером (письма, статус в панели)
Сообщите хостеру, если файрвол ни при чём" "Check the firewall's outbound rules
Check whether the provider blocked the server (e-mails, panel status)
Contact the provider if the firewall is not the cause") ("gateway: " + (($gw | ForEach-Object { $_.NextHop }) -join ','))
} elseif (-not $dns) {
    $netOk = $false
    Add-F 2 'net' 87 'h' (L 'Не работает DNS: имена сайтов не превращаются в адреса (интернет при этом есть)' 'DNS is broken: names do not resolve (the internet itself works)') `
        (L 'Компьютер не может узнать адрес по имени, поэтому не работают обновления, почта, запросы к API - всё, что обращается по имени.' 'The machine cannot resolve names, so updates, mail, API calls - everything that uses names - fail.') `
        (L "Посмотрите, какие DNS-серверы указаны: ipconfig /all
Пропишите рабочие DNS - от хостера или публичные, например 1.1.1.1 и 8.8.8.8 (Свойства адаптера → IPv4)
Проверьте, не блокирует ли брандмауэр порт 53" "See which DNS servers are set: ipconfig /all
Set working DNS servers - your provider's or public ones such as 1.1.1.1 and 8.8.8.8 (adapter properties → IPv4)
Check that the firewall does not block port 53") ((Get-DnsClientServerAddress -AddressFamily IPv4 | ForEach-Object { $_.ServerAddresses }) -join ', ')
}
$pingRtt = $null
if ($inet) {
    $png = New-Object System.Net.NetworkInformation.Ping; $okN = 0; $rtts = @()
    for ($i = 0; $i -lt 5; $i++) { try { $r = $png.Send('1.1.1.1', 2000); if ($r.Status -eq 'Success') { $okN++; $rtts += $r.RoundtripTime } } catch { } }
    $loss = 100 - $okN * 20
    Tech ("ping 1.1.1.1 x5: loss $loss%, rtt " + ($rtts -join ','))
    if ($okN -eq 0) { Note (L 'Ping (ICMP) до интернета не проходит, хотя соединения работают - ICMP просто фильтруется, это не ошибка.' 'Ping (ICMP) does not pass although connections work - ICMP is filtered; not an error.') }
    else {
        $pingRtt = [math]::Round(($rtts | Measure-Object -Average).Average)
        if ($loss -ge 20) {
            Add-F 1 'net' 46 'm' (L "Потери пакетов до интернета: $loss%" "Packet loss to the internet: $loss%") `
                (L 'Часть пакетов теряется по дороге: сайты открываются с задержками, удалённый рабочий стол «подтормаживает», загрузки обрываются.' 'Some packets are lost on the way: sites load with delays, Remote Desktop lags, downloads break.') `
                (L "Повторите проверку через несколько минут - разовая ли это проблема
Если повторяется - напишите хостеру: «потери пакетов $loss% до 1.1.1.1», приложите результат: pathping 1.1.1.1" "Re-run the check in a few minutes - is it a one-off?
If it repeats, tell your provider: `"$loss% packet loss to 1.1.1.1`" and attach: pathping 1.1.1.1") "loss $loss%"
        }
        $buf = New-Object byte[] 1472; $opt = New-Object System.Net.NetworkInformation.PingOptions(64, $true); $big = 0
        for ($i = 0; $i -lt 2; $i++) { try { $r = $png.Send('1.1.1.1', 2000, $buf, $opt); if ($r.Status -eq 'Success') { $big++ } } catch { } }
        $mtu = @(Get-NetIPInterface -AddressFamily IPv4 -ConnectionState Connected | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } | ForEach-Object { $_.NlMtu } | Sort-Object -Descending | Select-Object -First 1)
        if ($big -eq 0 -and $mtu.Count -gt 0 -and $mtu[0] -ge 1500) {
            Add-F 1 'net' 35 'l' (L 'Возможна проблема MTU: большие пакеты (1500 байт) теряются, маленькие проходят' 'Possible MTU problem: large packets (1500 bytes) are lost while small ones pass') `
                (L 'Если по пути есть туннель или VPN с меньшим MTU, большие пакеты пропадают: сайты открываются частично, удалённый рабочий стол зависает, загрузки «замирают».' 'If a tunnel/VPN with a smaller MTU is on the path, large packets vanish: pages load partially, Remote Desktop hangs, downloads stall.') `
                (L "Если такие симптомы есть - попробуйте временно MTU 1400 и сравните (netsh interface ipv4 set subinterface ... mtu=1400 - это уже изменение, поручите специалисту)
Сообщите хостеру: «теряются пакеты 1500 байт с флагом DF»" "If you see such symptoms, try MTU 1400 temporarily and compare (netsh interface ipv4 set subinterface ... mtu=1400 - a change, ask an admin)
Tell your provider: `"1500-byte packets with DF are dropped`"") "DF ping 1472 bytes: 0/2 replies; interface MTU $($mtu[0])"
        }
    }
}
$nics = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
Tech ($nics | Select-Object Name, InterfaceDescription, LinkSpeed, FullDuplex, MacAddress | Format-Table -AutoSize)
$nicBad = @()
foreach ($n in $nics) {
    $st = Get-NetAdapterStatistics -Name $n.Name
    if ($st) {
        $err = [double]$st.ReceivedPacketErrors + [double]$st.OutboundPacketErrors
        $pk = [double]$st.ReceivedUnicastPackets + [double]$st.SentUnicastPackets + 1
        if ($err -ge 1000 -and $err / $pk -ge 0.0001) { $nicBad += ('{0}: errors {1} of {2} packets' -f $n.Name, $err, $pk) }
    }
    if ($n.FullDuplex -eq $false) { $nicBad += ('{0}: half duplex' -f $n.Name) }
    if (-not $IsVM -and $n.ReceiveLinkSpeed -gt 0 -and $n.ReceiveLinkSpeed -le 100000000) { $nicBad += ('{0}: link speed {1}' -f $n.Name, $n.LinkSpeed) }
}
if ($nicBad.Count -gt 0) {
    Add-F 1 'net' 44 'm' (L "Сетевая карта работает с ошибками или на низкой скорости: $($nicBad -join '; ')" "The network card has errors or a low link speed: $($nicBad -join '; ')") `
        (L 'Ошибки приёма/передачи, полудуплекс или скорость 100 Мбит/с обычно означают плохой кабель, порт коммутатора или драйвер.' 'Receive/transmit errors, half duplex or 100 Mbit/s usually mean a bad cable, switch port or driver.') `
        (L "Попросите дата-центр проверить кабель и порт коммутатора
Обновите драйвер сетевой карты" "Ask the data center to check the cable and the switch port
Update the network card driver") ($nicBad -join "`n")
}
# time: compare the clock with an HTTP Date header (language-independent)
Sec 'Time'
Tech ((w32tm /query /status 2>&1) -join "`n")
$drift = $null
if ($inet) {
    foreach ($u in 'http://www.msftconnecttest.com/connecttest.txt', 'http://www.google.com/', 'http://ya.ru/') {
        try {
            $rq = [System.Net.HttpWebRequest]::Create($u); $rq.Method = 'HEAD'; $rq.Timeout = 5000; $rq.AllowAutoRedirect = $false
            $rs = $rq.GetResponse(); $hd = $rs.Headers['Date']; $rs.Close()
        } catch [System.Net.WebException] { $hd = $null; if ($_.Exception.Response) { $hd = $_.Exception.Response.Headers['Date'] } }
        catch { $hd = $null }
        if ($hd) { $drift = [math]::Round(((Get-Date).ToUniversalTime() - [DateTime]::Parse($hd, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()).TotalSeconds); break }
    }
}
$w32 = Get-Service W32Time
Tech ("clock - HTTP Date = $drift s; W32Time: $($w32.Status)")
if ($null -ne $drift -and [math]::Abs($drift) -ge 10) {
    $ad = [math]::Abs($drift); $sev = 1; $sc = 50; if ($ad -ge 120) { $sev = 2; $sc = 75 }
    Add-F $sev 'net' $sc 'h' (L "Часы компьютера отстают/спешат на $ad секунд" "The clock is off by $ad seconds") `
        (L 'Неточное время ломает HTTPS-сертификаты, вход по одноразовым кодам (2FA), подписи API, вход в домен и порядок записей в журналах.' 'A wrong clock breaks HTTPS certificates, one-time codes (2FA), API signatures, domain logons and log order.') `
        (L "Включите синхронизацию: Параметры → Время и язык → Дата и время → «Синхронизировать» (на сервере - служба «Служба времени Windows» должна работать)
Проверьте источник времени: w32tm /query /status
Если сервер виртуальный и часы снова уходят - сообщите хостеру" "Enable sync: Settings → Time & language → Date & time → Sync now (on a server the Windows Time service must run)
Check the time source: w32tm /query /status
If the server is virtual and the clock drifts again, tell your provider") "clock - HTTP Date = $drift s; W32Time $($w32.Status)"
}
if ($netOk) {
    $nok = L 'интернет и DNS работают' 'internet and DNS work'
    if ($null -ne $pingRtt) { $nok += ", ping $pingRtt ms" }
    if ($null -ne $drift) { $nok += (L ", часы точные (±$([math]::Abs($drift)) с)" ", clock accurate (±$([math]::Abs($drift)) s)") }
    $OK['net'] = $nok
}
Tech (Get-NetTCPConnection -State Listen | Sort-Object LocalPort -Unique | Select-Object -First 40 LocalAddress, LocalPort, OwningProcess | Format-Table -AutoSize)

# ================================================================== VERDICT
$Areas = @('disk', 'mem', 'cpu', 'crash', 'svc', 'net')
function Area-Name([string]$a) {
    switch ($a) {
        'disk' { L 'Диски' 'Disks' } 'mem' { L 'Память (ОЗУ)' 'Memory (RAM)' } 'cpu' { L 'Процессор и температура' 'CPU & temperature' }
        'crash' { L 'Сбои и перезагрузки' 'Crashes & reboots' } 'svc' { L 'Службы и программы' 'Services & programs' } 'net' { L 'Сеть и время' 'Network & time' }
    }
}
function Conf-Name([string]$c) { switch ($c) { 'h' { L 'высокая' 'high' } 'm' { L 'средняя' 'medium' } default { L 'низкая' 'low' } } }
function Light([int]$s) { switch ($s) { 2 { [char]::ConvertFromUtf32(0x1F534) } 1 { [char]::ConvertFromUtf32(0x1F7E1) } default { [char]::ConvertFromUtf32(0x1F7E2) } } }
function Word([int]$s) { switch ($s) { 2 { L 'ПРОБЛЕМА' 'PROBLEM' } 1 { L 'ВНИМАНИЕ' 'WARNING' } default { L 'НОРМА' 'OK' } } }
function Col([int]$s) { switch ($s) { 2 { 'Red' } 1 { 'Yellow' } default { 'Green' } } }
$Order = @($F | Sort-Object @{e = { $_.Score }; Descending = $true }, @{e = { $_.N } })
$AW = @{}; $AT = @{}; $AN = @{}
foreach ($f in $Order) {
    $AN[$f.Area] = [int]$AN[$f.Area] + 1
    if ($f.Sev -gt [int]$AW[$f.Area]) { $AW[$f.Area] = $f.Sev; $AT[$f.Area] = $f.Title }
}
$Worst = 0; foreach ($a in $Areas) { if ([int]$AW[$a] -gt $Worst) { $Worst = [int]$AW[$a] } }
$Overall = switch ($Worst) { 2 { L 'ЕСТЬ СЕРЬЁЗНАЯ ПРОБЛЕМА' 'A SERIOUS PROBLEM WAS FOUND' } 1 { L 'РАБОТАЕТ, НО ЕСТЬ НА ЧТО ОБРАТИТЬ ВНИМАНИЕ' 'WORKING, BUT SOME THINGS NEED ATTENTION' } default { L 'ВСЁ В НОРМЕ - серьёзных проблем не найдено' 'ALL GOOD - no serious problems found' } }
$NoProb = L "Ничего срочного делать не нужно - компьютер в порядке
Если он всё равно «тормозит» или падает - запустите проверку ещё раз прямо в момент проблемы: так видно, что именно перегружено
Сохраните этот отчёт: при следующей проблеме будет с чем сравнить" "Nothing urgent to do - the machine is healthy
If it still feels slow or crashes, run the check again right when the problem happens: that shows what is overloaded
Keep this report: next time you will have something to compare with"
function Area-Text([string]$a) {
    $w = [int]$AW[$a]
    if ($w -eq 0) { if ($OK[$a]) { return (L 'норма' 'OK') + ' - ' + $OK[$a] } else { return (L 'норма (проверено частично)' 'OK (partially checked)') } }
    $t = $AT[$a]; if ($AN[$a] -gt 1) { $t += (L " (+ ещё $($AN[$a] - 1))" " (+$($AN[$a] - 1) more)") }; return $t
}
$Elapsed = [math]::Round(((Get-Date) - $T0).TotalSeconds)

# ---- HTML report
function Enc([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }   # not "H": that is the built-in alias of Get-History
$Report = $null
if (-not $NoHtml) {
    $dirs = @($OutDir, [Environment]::GetFolderPath('Desktop'), $PSScriptRoot, $env:TEMP) | Where-Object { $_ -and (Test-Path $_ -PathType Container) }
    $name = 'server-diag-report-{0}-{1}.html' -f $HostName, (Get-Date -Format 'yyyy-MM-dd')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("<!DOCTYPE html><html lang=`"$Lang`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width,initial-scale=1`">")
    [void]$sb.AppendLine("<title>server-diag: $(Enc $HostName) - $(Fmt-Date (Get-Date))</title>")
    [void]$sb.AppendLine('<style>body{font:15px/1.55 -apple-system,"Segoe UI",Roboto,Arial,sans-serif;margin:0;background:#f3f5f8;color:#1c2330}main{max-width:980px;margin:0 auto;padding:22px}.card{background:#fff;border-radius:12px;padding:18px 22px;margin:0 0 16px;box-shadow:0 1px 3px rgba(0,0,0,.08)}h1{font-size:22px;margin:0 0 4px}h2{font-size:18px;margin:0 0 10px}.meta{color:#5b6475;font-size:13.5px}.verdict{font-size:21px;font-weight:700;padding:16px 20px;border-radius:12px;margin:0 0 16px}.v2{background:#fde8e8;color:#9b1c1c}.v1{background:#fdf3d8;color:#7a4d00}.v0{background:#e3f5e9;color:#1d6436}table{border-collapse:collapse;width:100%}td{padding:9px 6px;border-bottom:1px solid #eef0f3;vertical-align:top}td.l{font-size:19px;width:30px}td.a{font-weight:600;width:240px}.f{border-left:5px solid #c9ced6;padding:10px 14px;margin:12px 0;background:#fafbfc;border-radius:8px}.f.s2{border-color:#e02424}.f.s1{border-color:#e3a008}.f h3{margin:0 0 6px;font-size:16px}ol{margin:6px 0 4px 22px;padding:0}li{margin:3px 0}.conf{font-size:12.5px;color:#5b6475}pre{background:#101820;color:#d7e3f1;padding:12px;border-radius:8px;overflow:auto;font-size:12.5px;white-space:pre-wrap;word-break:break-word}details{margin:8px 0}summary{cursor:pointer;font-weight:600}ul{margin:6px 0 0 20px;padding:0}footer{color:#5b6475;font-size:12.5px;text-align:center;margin:18px 0}</style></head><body><main>')
    [void]$sb.AppendLine("<div class=`"card`"><h1>$(Enc ((L 'Диагностика Windows ' 'Windows diagnostics ') + $HostName))</h1><div class=`"meta`">$(Enc ("{0} · {1} (build {2}) · {3} {4} · {5} {6} · {7}, {8} {9}" -f (Fmt-Date (Get-Date)), $os.Caption, $os.BuildNumber, $Cores, (L 'лог. процессоров' 'logical CPUs'), (Fmt-Bytes $memT), (L 'ОЗУ' 'RAM'), $Kind, (L 'работает' 'up'), (Fmt-Dur $Up)))</div></div>")
    [void]$sb.AppendLine("<div class=`"verdict v$Worst`">$(Light $Worst) $(Enc (L 'Итог' 'Result')): $(Enc $Overall)</div>")
    [void]$sb.AppendLine("<div class=`"card`"><h2>$(Enc (L 'Светофор по областям' 'Traffic light by area'))</h2><table>")
    foreach ($a in $Areas) { [void]$sb.AppendLine("<tr><td class=`"l`">$(Light ([int]$AW[$a]))</td><td class=`"a`">$(Enc (Area-Name $a))</td><td>$(Enc (Area-Text $a))</td></tr>") }
    [void]$sb.AppendLine('</table></div>')
    [void]$sb.AppendLine("<div class=`"card`"><h2>$(Enc (L 'Главная причина и что сделать' 'Main cause and what to do'))</h2>")
    if ($Order.Count -gt 0) {
        $i = 0
        foreach ($f in $Order) {
            if ($i -eq 1) { [void]$sb.AppendLine("<h2 style=`"margin-top:18px`">$(Enc (L 'Ещё замечено' 'Also found'))</h2>") }
            [void]$sb.AppendLine("<div class=`"f s$($f.Sev)`"><h3>$(Light $f.Sev) $(Enc $f.Title)</h3><div class=`"conf`">$(Enc (Area-Name $f.Area)) · $(Enc (L 'уверенность' 'confidence')): $(Enc (Conf-Name $f.Conf))</div><p>$(Enc $f.Why)</p><ol>")
            foreach ($s in ($f.Do -split "`r?`n")) { if ($s.Trim()) { [void]$sb.AppendLine("<li>$(Enc $s.Trim())</li>") } }
            [void]$sb.AppendLine('</ol>')
            if ($f.Ev) { [void]$sb.AppendLine("<details><summary>$(Enc (L 'Доказательства' 'Evidence'))</summary><pre>$(Enc $f.Ev)</pre></details>") }
            [void]$sb.AppendLine('</div>'); $i++
        }
    } else {
        [void]$sb.AppendLine("<p>$(Light 0) $(Enc (L 'Проблем не найдено - все проверенные области в норме.' 'No problems found - every checked area is fine.'))</p><ol>")
        foreach ($s in ($NoProb -split "`r?`n")) { [void]$sb.AppendLine("<li>$(Enc $s)</li>") }
        [void]$sb.AppendLine('</ol>')
    }
    [void]$sb.AppendLine('</div>')
    if ($Notes.Count -gt 0 -or $Limits.Count -gt 0) {
        [void]$sb.AppendLine("<div class=`"card`"><h2>$(Enc (L 'К сведению / не проверено' 'Notes / not checked'))</h2><ul>")
        foreach ($s in (@($Limits) + @($Notes))) { [void]$sb.AppendLine("<li>$(Enc $s)</li>") }
        [void]$sb.AppendLine('</ul></div>')
    }
    [void]$sb.AppendLine("<div class=`"card`"><h2>$(Enc (L 'Технические подробности' 'Technical details'))</h2><p class=`"meta`">$(Enc (L 'Сырые данные для специалиста: результаты команд и запросов, которыми проверялся компьютер.' 'Raw data for an admin: output of the queries used for the check.'))</p>")
    $open = $false
    foreach ($ln in ($Tech.ToString() -split "`r?`n")) {
        if ($ln -like '=== *') { if ($open) { [void]$sb.AppendLine('</pre></details>') }; [void]$sb.AppendLine("<details><summary>$(Enc $ln.Substring(4))</summary><pre>"); $open = $true }
        elseif ($open) { [void]$sb.AppendLine((Enc $ln)) }
    }
    if ($open) { [void]$sb.AppendLine('</pre></details>') }
    [void]$sb.AppendLine("</div><footer>server-diag $VERSION · $(Enc (L "только чтение - скрипт ничего не менял; проверка заняла $Elapsed сек." "read-only - the script changed nothing; the check took $Elapsed s.")) · <a href=`"https://github.com/vadimpokrov396-ship-it/server-diag`">github.com/vadimpokrov396-ship-it/server-diag</a></footer></main></body></html>")
    foreach ($d in $dirs) {
        $p = Join-Path $d $name
        if (Test-Path $p) { $p = Join-Path $d ('server-diag-report-{0}-{1}.html' -f $HostName, (Get-Date -Format 'yyyy-MM-dd-HHmmss')) }
        try { [System.IO.File]::WriteAllText($p, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true)); $Report = $p; break } catch { }
    }
}

# ---- console verdict
$line = '=' * 72
$wName = ($Areas | ForEach-Object { (Area-Name $_).Length } | Measure-Object -Maximum).Maximum
Write-Host ''
Write-Host $line
Write-Host (' ' + (L 'ДИАГНОСТИКА WINDOWS' 'WINDOWS DIAGNOSTICS') + " · $HostName · " + (Fmt-Date (Get-Date))) -ForegroundColor White
Write-Host (" {0} (build {1}) · {2} {3} · {4} {5} · {6}, {7} {8}" -f $os.Caption, $os.BuildNumber, $Cores, (L 'лог. процессоров' 'logical CPUs'), (Fmt-Bytes $memT), (L 'ОЗУ' 'RAM'), $Kind, (L 'работает' 'up'), (Fmt-Dur $Up))
Write-Host $line
Write-Host ''
Write-Host (' ' + (L 'ИТОГ' 'RESULT') + ': ' + $Overall) -ForegroundColor (Col $Worst)
Write-Host ''
foreach ($a in $Areas) {
    $w = [int]$AW[$a]
    Write-Host ' ' -NoNewline
    Write-Host ([char]0x25CF) -ForegroundColor (Col $w) -NoNewline
    Write-Host (' {0,-9} ' -f (Word $w)) -ForegroundColor (Col $w) -NoNewline
    Write-Host ((Area-Name $a).PadRight($wName) + '  ') -ForegroundColor White -NoNewline
    Write-Host (Area-Text $a)
}
Write-Host ''
if ($Order.Count -gt 0) {
    $m = $Order[0]
    Write-Host (' ' + (L 'ГЛАВНАЯ ПРИЧИНА' 'MAIN CAUSE') + '  (' + (L 'уверенность' 'confidence') + ': ' + (Conf-Name $m.Conf) + ')') -ForegroundColor White
    Write-Host ('   ' + (Word $m.Sev) + ': ' + $m.Title) -ForegroundColor (Col $m.Sev)
    Write-Host ('   ' + $m.Why)
    Write-Host ''
    Write-Host (' ' + (L 'ЧТО СДЕЛАТЬ' 'WHAT TO DO')) -ForegroundColor White
    $k = 0; foreach ($s in ($m.Do -split "`r?`n")) { if ($s.Trim() -and $k -lt 3) { $k++; Write-Host ("   $k) " + $s.Trim()) } }
    if ($Order.Count -gt 1) {
        Write-Host ''
        Write-Host (' ' + (L 'ЕЩЁ ЗАМЕЧЕНО' 'ALSO FOUND')) -ForegroundColor White
        foreach ($f in ($Order | Select-Object -Skip 1)) {
            Write-Host '   ' -NoNewline; Write-Host ([char]0x25CF) -ForegroundColor (Col $f.Sev) -NoNewline; Write-Host (' ' + $f.Title)
            Write-Host ('      -> ' + (($f.Do -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)) -ForegroundColor Gray
        }
    }
} else {
    Write-Host (' ' + (L 'ГЛАВНАЯ ПРИЧИНА' 'MAIN CAUSE')) -ForegroundColor White
    Write-Host ('   ' + (L 'проблем не найдено - все проверенные области в норме.' 'no problems found - every checked area is fine.')) -ForegroundColor Green
    Write-Host ''
    Write-Host (' ' + (L 'ЧТО СДЕЛАТЬ' 'WHAT TO DO')) -ForegroundColor White
    $k = 0; foreach ($s in ($NoProb -split "`r?`n")) { $k++; Write-Host ("   $k) " + $s) }
}
if ($Notes.Count -gt 0 -or $Limits.Count -gt 0) {
    Write-Host ''
    Write-Host (' ' + (L 'К СВЕДЕНИЮ / НЕ ПРОВЕРЕНО' 'NOTES / NOT CHECKED')) -ForegroundColor White
    foreach ($s in (@($Limits) + @($Notes))) { Write-Host ('   - ' + $s) }
}
Write-Host ''
Write-Host (' ' + (L 'ТЕХНИЧЕСКИЕ ПОДРОБНОСТИ (главное)' 'TECHNICAL DETAILS (key facts)')) -ForegroundColor White
Write-Host ("   cpu: {0}% busy (3 s), queue {1}; top cpu: {2}" -f $CpuBusy, $Queue, $(if ($TopCpuH) { $TopCpuH } else { '-' })) -ForegroundColor Gray
Write-Host ("   ram: available {0} / {1} ({2}%), commit {3}%, page-ins {4}/s; top ram: {5}" -f (Fmt-Bytes $memA), (Fmt-Bytes $memT), $AP, $CP, $PagesIn, $TopMemH) -ForegroundColor Gray
Write-Host ("   disk: {0} ms per operation at {1} IOPS (3 s sample)" -f $DiskMs, $Iops) -ForegroundColor Gray
foreach ($f in $Order) { if ($f.Ev) { $ev1 = (($f.Ev -split "`r?`n") | Select-Object -First 3 | ForEach-Object { if ($_.Length -gt 200) { $_.Substring(0, 200) + '...' } else { $_ } }) -join "`n      "; Write-Host ("   [{0}] {1}" -f (Area-Name $f.Area), $ev1) -ForegroundColor Gray } }
Write-Host ''
if ($Report) {
    Write-Host (' ' + (L 'Полный отчёт сохранён: ' 'Full report saved: ') + $Report) -ForegroundColor Cyan
    Write-Host ('   ' + (L 'Откройте его в браузере или отправьте специалисту.' 'Open it in a browser or send it to an admin.'))
}
Write-Host (' ' + (L "Проверка заняла $Elapsed сек. Скрипт ничего не менял в системе." "The check took $Elapsed s. The script changed nothing in the system."))
Write-Host ''
if ($Report -and $Pause -and -not $NoOpen) { try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Report) } catch { } }
if ($Pause) { [void](Read-Host (L 'Нажмите Enter, чтобы закрыть окно' 'Press Enter to close this window')) }
