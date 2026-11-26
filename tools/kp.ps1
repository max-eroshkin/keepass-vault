<#
.SYNOPSIS
    kp.ps1 — KeePassXC + git синхронизация (Windows)

.DESCRIPTION
    kp.ps1 open     pull (если безопасно) -> открыть базу -> commit+push после выхода
    kp.ps1 sync     commit+push; безопасный pull, если база закрыта
    kp.ps1 merge    слить расходящиеся версии базы
    kp.ps1 status   состояние синхронизации

    Переменные: KP_VAULT_DIR, KP_DB_NAME, KP_BRANCH, KP_REMOTE, KPXC
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('open', 'sync', 'merge', 'status', 'help')]
    [string]$Command = 'help'
)

$ErrorActionPreference = 'Stop'

$VaultDir = if ($env:KP_VAULT_DIR) { $env:KP_VAULT_DIR } else { Join-Path $env:USERPROFILE 'Vault' }
$DbName   = if ($env:KP_DB_NAME)   { $env:KP_DB_NAME }   else { 'passwords.kdbx' }
$Branch   = if ($env:KP_BRANCH)    { $env:KP_BRANCH }    else { 'main' }
$Remote   = if ($env:KP_REMOTE)    { $env:KP_REMOTE }    else { 'origin' }
$Db       = Join-Path $VaultDir $DbName
$Conflicts = Join-Path $VaultDir 'conflicts'
$HostName = $env:COMPUTERNAME

function Log($msg) { Write-Host "kp: $msg" }
function Die($msg) { Write-Error "kp: $msg"; exit 1 }

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    Push-Location $VaultDir
    try { & git @Args 2>$null } finally { Pop-Location }
}

function Get-GitOut {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    Push-Location $VaultDir
    try { (& git @Args 2>$null) -join "`n" } finally { Pop-Location }
}

function Test-Repo { Test-Path (Join-Path $VaultDir '.git') }
function Test-Db { (Test-Path $Db) -and ((Get-Item $Db).Length -gt 0) }
function Test-AppRunning { [bool](Get-Process -Name 'KeePassXC' -ErrorAction SilentlyContinue) }

function Test-Kdbx($path) {
    if (-not (Test-Path $path)) { return $false }
    $fs = [System.IO.File]::OpenRead($path)
    try {
        $buf = New-Object byte[] 4
        $null = $fs.Read($buf, 0, 4)
        return ($buf[0] -eq 0x03 -and $buf[1] -eq 0xD9 -and $buf[2] -eq 0xA2 -and $buf[3] -eq 0x9A)
    } finally { $fs.Dispose() }
}

function Test-DbDirty {
    $status = Get-GitOut status --porcelain -- $DbName
    return [bool]($status -and $status.Trim())
}

function Get-Divergence {
    $result = [pscustomobject]@{ Ahead = 0; Behind = 0 }
    if (-not (Get-GitOut rev-parse --verify -q HEAD)) { return $result }
    $remoteRef = "refs/remotes/$Remote/$Branch"
    if (-not (Get-GitOut rev-parse --verify -q $remoteRef)) { return $result }
    $counts = (Get-GitOut rev-list --count --left-right "HEAD...$Remote/$Branch") -split '\s+'
    $result.Ahead = [int]$counts[0]
    $result.Behind = [int]$counts[1]
    return $result
}

function Confirm-Db {
    if (-not (Test-Db)) { return $true }
    if (-not (Test-Kdbx $Db)) { Log "Файл $DbName не похож на KDBX — коммит пропущен"; return $false }
    if (Test-DbDirty) {
        Invoke-Git add -- $DbName | Out-Null
        $msg = "sync($HostName): $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Invoke-Git commit -q -m $msg | Out-Null
        Log "коммит создан"
    }
    return $true
}

function Push-Db {
    if (-not (Get-GitOut rev-parse --verify -q HEAD)) { return $true }
    Invoke-Git push -q $Remote "HEAD:$Branch" | Out-Null
    if ($LASTEXITCODE -ne 0) { Log 'не удалось запушить — проверьте сеть/доступ'; return $false }
    Log 'push: успешно'
    return $true
}

function Invoke-Fetch {
    Invoke-Git fetch --prune $Remote | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-FfPull {
    if (Test-AppRunning) { Log 'KeePassXC запущен — pull отложен'; return $false }
    Invoke-Git merge --ff-only -q "$Remote/$Branch" | Out-Null
    if ($LASTEXITCODE -eq 0) { Log 'база обновлена с другого устройства'; return $true }
    return $false
}

function Find-KeepassXc {
    if ($env:KPXC) { return $env:KPXC }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'KeePassXC\KeePassXC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'KeePassXC\KeePassXC.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return 'KeePassXC.exe'
}

function Cmd-Merge {
    if (-not (Test-Repo)) { Die "нет git-репозитория в $VaultDir" }
    if (-not (Invoke-Fetch)) { Log 'нет связи с git'; return }
    $d = Get-Divergence
    if ($d.Ahead -eq 0 -and $d.Behind -eq 0) { Log 'сливать нечего'; return }
    if (Test-AppRunning) { Log 'закройте KeePassXC перед слиянием'; return }
    if (-not (Test-Db)) { Log 'локальной базы нет'; return }
    if (-not (Confirm-Db)) { return }

    Invoke-Fetch | Out-Null
    $d = Get-Divergence
    if ($d.Behind -eq 0) { Push-Db | Out-Null; return }

    New-Item -ItemType Directory -Force -Path $Conflicts | Out-Null
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $remoteCopy = Join-Path $Conflicts "remote-$HostName-$ts.kdbx"
    $localCopy  = Join-Path $Conflicts "local-$HostName-$ts.kdbx"

    Push-Location $VaultDir
    try { & git show "$Remote/$Branch`:$DbName" > $remoteCopy } finally { Pop-Location }
    Copy-Item -Force $Db $localCopy

    Log "Версия из git сохранена: $remoteCopy"
    Log 'Откройте базу в KeePassXC и выполните: Database -> Merge from database -> выберите файл выше'
    Log 'После сохранения базы запустите kp.ps1 sync повторно.'
    Start-Process (Find-KeepassXc) -ArgumentList "`"$Db`""
}

function Cmd-Sync {
    if (-not (Test-Repo)) { Die "нет git-репозитория в $VaultDir" }
    if (-not (Test-Db)) { Log "базы ещё нет: $Db"; return }
    $null = Invoke-Fetch
    $null = Confirm-Db
    $d = Get-Divergence

    if (Test-AppRunning) {
        Push-Db | Out-Null
        if ($d.Behind -gt 0) { Log 'в git есть изменения с другого устройства — после закрытия KeePassXC выполните kp.ps1 merge' }
        return
    }
    if ($d.Ahead -gt 0 -and $d.Behind -gt 0) {
        Push-Db | Out-Null
        Log 'версии разошлись — выполните kp.ps1 merge'
        return
    }
    if ($d.Behind -gt 0 -and $d.Ahead -eq 0) { Invoke-FfPull | Out-Null }
    Push-Db | Out-Null
}

function Cmd-Open {
    if (-not (Test-Repo)) { Die "нет git-репозитория в $VaultDir" }
    $null = Invoke-Fetch

    if (Test-Db) {
        $null = Confirm-Db
        $d = Get-Divergence
        if ($d.Ahead -gt 0 -and $d.Behind -gt 0) {
            Log 'версии разошлись — запускаю слияние'
            Cmd-Merge
        } elseif ($d.Behind -gt 0) {
            Invoke-FfPull | Out-Null
        }
    }

    $exe = Find-KeepassXc
    if (Test-Db) { Start-Process $exe -ArgumentList "`"$Db`"" -Wait } else { Start-Process $exe -Wait }

    $null = Confirm-Db
    $d = Get-Divergence
    if ($d.Ahead -gt 0 -and $d.Behind -gt 0) {
        Log 'появились изменения с другого устройства — выполните kp.ps1 merge'
    } else {
        Push-Db | Out-Null
    }
}

function Cmd-Status {
    if (-not (Test-Repo)) { Die "нет git-репозитория в $VaultDir" }
    Write-Host "репозиторий : $VaultDir"
    Write-Host "база        : $Db $(if (Test-Path $Db) { '(есть)' } else { '(нет)' })"
    Write-Host "ветка       : $Branch (remote: $Remote)"
    Write-Host "KeePassXC   : $(if (Test-AppRunning) { 'запущен' } else { 'закрыт' })"
    $null = Invoke-Fetch
    $head = Get-GitOut log -1 --format='%h %s (%cr)'
    Write-Host "HEAD        : $(if ($head) { $head } else { 'коммитов нет' })"
    $d = Get-Divergence
    Write-Host "ahead/behind: $($d.Ahead) / $($d.Behind)"
    Write-Host "изменения   : $(if (Test-DbDirty) { 'есть' } else { 'нет' })"
}

$mutex = New-Object System.Threading.Mutex($false, 'Global\KeepassVaultSync')
if (-not $mutex.WaitOne(0)) { Log 'синхронизация уже выполняется — пропускаю'; exit 0 }
try {
    switch ($Command) {
        'open'   { Cmd-Open }
        'sync'   { Cmd-Sync }
        'merge'  { Cmd-Merge }
        'status' { Cmd-Status }
        default  {
            Write-Host @'
kp.ps1 — KeePassXC + git (Windows)

  kp.ps1 open     pull (если безопасно) -> открыть базу -> commit+push
  kp.ps1 sync     commit+push; pull, если база закрыта
  kp.ps1 merge    слить расходящиеся версии базы
  kp.ps1 status   состояние синхронизации
'@
        }
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
