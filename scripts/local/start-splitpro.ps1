# Starts the local SplitPro stack. Run from a normal (not sandboxed) PowerShell session.
# It is deliberately conservative: it does not expose ports beyond loopback and does
# not modify existing browser profiles.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$pgBin = Join-Path $root '.local\pgsql\bin'
$data = Join-Path $root '.local\pgdata-live'
$logs = Join-Path $root '.local\logs'
$node22 = Join-Path $root '.local\runtime\node-v22.16.0-win-x64\node.exe'
$mailpit = Join-Path $root '.local\tools\mailpit\mailpit.exe'

New-Item -ItemType Directory -Force -Path $logs | Out-Null
$env:PGPASSFILE = Join-Path $root '.local\pgpass.conf'
$env:NODE_ENV = 'production'
$env:NEXT_TELEMETRY_DISABLED = '1'

function Test-LocalPort([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Port)
        return $true
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

if (-not (Test-LocalPort 55433)) {
    Write-Output 'Starting PostgreSQL on 127.0.0.1:55433...'
    & (Join-Path $pgBin 'pg_ctl.exe') -D $data -l (Join-Path $logs 'postgres-start.log') start -w -t 90
    if ($LASTEXITCODE -ne 0) {
        Write-Output 'pg_ctl was blocked; trying direct postgres start.'
        Start-Process -FilePath (Join-Path $pgBin 'postgres.exe') `
            -ArgumentList @('-D', $data) `
            -WorkingDirectory $root -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $logs 'postgres.out.log') `
            -RedirectStandardError (Join-Path $logs 'postgres.err.log') | Out-Null
    }
}

if (-not (Test-LocalPort 1125) -or -not (Test-LocalPort 8025)) {
    Write-Output 'Starting local-only Mailpit on 127.0.0.1:1125 / 127.0.0.1:8025...'
    Start-Process -FilePath $mailpit `
        -ArgumentList @('--listen', '127.0.0.1:8025', '--smtp', '127.0.0.1:1125',
                        '--database', (Join-Path $root '.local\mailpit-data\mailpit.db'),
                        '--quiet', '--disable-version-check') `
        -WorkingDirectory $root -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logs 'mailpit.out.log') `
        -RedirectStandardError (Join-Path $logs 'mailpit.err.log') | Out-Null
}

if (-not (Test-LocalPort 3000)) {
    Write-Output 'Starting SplitPro on 127.0.0.1:3000...'
    if (-not (Test-Path $node22)) { throw "Pinned Node runtime missing: $node22" }
    Start-Process -FilePath $node22 `
        -ArgumentList @('node_modules\next\dist\bin\next', 'start', '-H', '127.0.0.1', '-p', '3000') `
        -WorkingDirectory $root -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logs 'app.out.log') `
        -RedirectStandardError (Join-Path $logs 'app.err.log') | Out-Null
}

$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
    if ((Test-LocalPort 3000) -and (Test-LocalPort 55433) -and (Test-LocalPort 1125)) { break }
    Start-Sleep -Seconds 1
}

if (-not (Test-LocalPort 3000)) { throw 'SplitPro did not start within 45 seconds.' }
if (-not (Test-LocalPort 55433)) { throw 'PostgreSQL did not start within 45 seconds.' }
$health = Invoke-RestMethod -Uri 'http://127.0.0.1:3000/api/healthz'
$ready = Invoke-RestMethod -Uri 'http://127.0.0.1:3000/api/readyz'
Write-Output "SplitPro is running at http://127.0.0.1:3000"
Write-Output ("healthz=" + ($health | ConvertTo-Json -Compress) + " readyz=" + ($ready | ConvertTo-Json -Compress))
Write-Output "Local mail testing UI: http://127.0.0.1:8025"
