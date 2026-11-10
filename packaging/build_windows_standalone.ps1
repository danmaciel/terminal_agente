$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

Write-Host "==> [1/3] Compilando Flutter Windows Release..."
flutter build windows --release

$ReleaseDir = Join-Path $ProjectRoot "build\windows\x64\runner\Release"
# Verify expected Flutter bundle files before creating any archive.
$RequiredFiles = @(
    (Join-Path $ReleaseDir "terminal_agente.exe"),
    (Join-Path $ReleaseDir "flutter_windows.dll"),
    (Join-Path $ReleaseDir "data\flutter_assets")
)
foreach ($RequiredPath in $RequiredFiles) {
    if (-not (Test-Path $RequiredPath)) {
        throw "Build Windows incompleto: $RequiredPath"
    }
}
$DistDir = Join-Path $ProjectRoot "dist"
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

$ZipPath = Join-Path $DistDir "TerminalAgente-windows-x64-standalone.zip"
if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
}

Write-Host "==> [2/3] Empacotando executável standalone e DLLs nativas (SQLite + PTY)..."
Compress-Archive -Path "$ReleaseDir\*" -DestinationPath $ZipPath
if (-not (Test-Path $ZipPath) -or (Get-Item $ZipPath).Length -eq 0) {
    throw "Pacote ZIP vazio ou ausente: $ZipPath"
}

Write-Host "==> [3/3] Concluído!"
Write-Host "    Executável direto: $ReleaseDir\terminal_agente.exe"
Write-Host "    Pacote Portátil:   $ZipPath"
