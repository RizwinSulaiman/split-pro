$ErrorActionPreference = 'Stop'
$base = 'http://127.0.0.1:3000'
$health = Invoke-RestMethod -Uri "$base/api/healthz"
$ready = Invoke-RestMethod -Uri "$base/api/readyz"
Write-Output ("healthz " + ($health | ConvertTo-Json -Compress))
Write-Output ("readyz  " + ($ready | ConvertTo-Json -Compress))

$client = New-Object System.Net.Sockets.TcpClient
try {
    $client.Connect('127.0.0.1', 3000)
    Write-Output "listener 127.0.0.1:3000 reachable=$($client.Connected)"
} finally {
    $client.Dispose()
}
