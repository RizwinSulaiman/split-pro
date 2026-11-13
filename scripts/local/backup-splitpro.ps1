param(
    [string]$Destination = 'L:\SplitPro-Backups'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$pgBin = Join-Path $root '.local\pgsql\bin'
$adminFile = Join-Path $root '.local\secrets\postgres_admin_password'
$envFile = Join-Path $root '.env'
if (-not (Test-Path $pgBin)) { throw "PostgreSQL binaries not found: $pgBin" }
if (-not (Test-Path $adminFile)) { throw "Admin secret not found: $adminFile" }
if (-not (Test-Path $envFile)) { throw "Environment file not found: $envFile" }

New-Item -ItemType Directory -Force -Path $Destination | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root 'uploads') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $root '.local\logs') | Out-Null

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dump = Join-Path $Destination "splitpro-$stamp.dump"
$uploads = Join-Path $Destination "splitpro-uploads-$stamp.tar.gz"
$manifestPath = Join-Path $Destination "manifest-$stamp.json"
$pgPass = (Get-Content -LiteralPath $adminFile -Raw).Trim()

try {
    $env:PGPASSWORD = $pgPass
    $env:PGPASSFILE = $null
    & (Join-Path $pgBin 'pg_dump.exe') -w -h 127.0.0.1 -p 55433 -U postgres `
        -d splitpro -Fc -f $dump
    if ($LASTEXITCODE -ne 0) { throw "pg_dump failed with exit code $LASTEXITCODE" }

    tar.exe -czf $uploads -C $root uploads
    if ($LASTEXITCODE -ne 0) { throw "receipt archive failed with exit code $LASTEXITCODE" }

    $manifest = [ordered]@{
        created_at   = (Get-Date).ToString('o')
        database     = 'splitpro'
        host         = '127.0.0.1'
        port         = 55433
        dump_file    = (Split-Path $dump -Leaf)
        dump_sha256  = (Get-FileHash -LiteralPath $dump -Algorithm SHA256).Hash.ToLower()
        dump_bytes   = (Get-Item -LiteralPath $dump).Length
        uploads_file = (Split-Path $uploads -Leaf)
        uploads_sha256 = (Get-FileHash -LiteralPath $uploads -Algorithm SHA256).Hash.ToLower()
        uploads_bytes = (Get-Item -LiteralPath $uploads).Length
        git_commit   = (& git -C $root rev-parse HEAD)
        note         = 'Local SplitPro backup. Contains financial data; keep on encrypted, access-controlled storage.'
    }
    [System.IO.File]::WriteAllText(
        $manifestPath,
        ($manifest | ConvertTo-Json -Depth 4),
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Output "Backup complete: $dump"
    Write-Output "Receipts:        $uploads"
    Write-Output "Manifest:        $manifestPath"
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}
