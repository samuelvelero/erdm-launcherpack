<#
    publicar-logica.ps1  —  publica una versión nueva de la LÓGICA del launcher

    La lógica del lado del jugador (erdm-logica.ps1) no viaja en el instalador:
    la descarga el lanzador fijo (erdm-launcher.ps1) desde este repo. Flujo:

      1. Edita erdm-logica.ps1 (en esta carpeta).
      2. .\publicar-logica.ps1 -Mensaje "..."
            Comprueba que parsea, crea v<N+1>\, actualiza logica.json y publica
            en la rama `logica-pruebas`. Solo la reciben las instalaciones con
            erdm-canal.txt = "pruebas" (la tuya).
      3. Prueba en tu PC (abre el launcher; mira erdm-launcher.log).
      4. .\publicar-logica.ps1 -Promover
            Lleva la rama `logica` al mismo commit: la reciben TODOS los jugadores.

    -LanzadorMinimo N : solo cuando la lógica nueva necesita algo que el lanzador
                        actual (API 1) no da. Los lanzadores más viejos se quedarán
                        con la última versión compatible.
    -SoloLocal        : prepara el commit pero no hace push.

    Nunca se reescribe una versión ya publicada: cada cambio es un v<N> nuevo.
#>

[CmdletBinding()]
param(
    [string]$Mensaje,
    [switch]$Promover,
    [int]$LanzadorMinimo = 0,
    [switch]$SoloLocal
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$utf8SinBom = New-Object System.Text.UTF8Encoding $false

$rama = (git rev-parse --abbrev-ref HEAD).Trim()
if ($rama -ne 'logica-pruebas') { throw "Esta carpeta debe estar en la rama 'logica-pruebas' (está en '$rama')." }

if ($Promover) {
    if (git status --porcelain) { throw 'Hay cambios sin publicar. Publica primero en pruebas (sin -Promover).' }
    git fetch -q origin
    $local = (git rev-parse HEAD).Trim()
    $enPruebas = (git rev-parse origin/logica-pruebas).Trim()
    if ($local -ne $enPruebas) { throw 'HEAD no coincide con origin/logica-pruebas: haz push de pruebas antes de promover.' }
    # Sin --force: si `logica` no es antecesora, git lo rechaza.
    git push origin logica-pruebas:logica
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo promover (¿logica tiene commits que pruebas no?).' }
    Write-Host 'Promovido: todos los jugadores recibirán esta lógica en su próximo arranque.' -ForegroundColor Green
    return
}

$fuente = Join-Path $PSScriptRoot 'erdm-logica.ps1'
if (-not (Test-Path $fuente)) { throw "Falta $fuente" }

# 1) ¿Parsea? Una lógica que no parsea no se publica.
$errores = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($fuente, [ref]$null, [ref]$errores)
if ($errores -and $errores.Count -gt 0) {
    $errores | ForEach-Object { Write-Warning "$($_.Extent.StartLineNumber): $($_.Message)" }
    throw 'erdm-logica.ps1 tiene errores de sintaxis. No se publica.'
}
$bytes = [System.IO.File]::ReadAllBytes($fuente)
if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
    throw 'erdm-logica.ps1 debe guardarse con BOM UTF-8 (PowerShell 5.1 corrompe los acentos sin él).'
}

# 2) Versión nueva
$rutaJson = Join-Path $PSScriptRoot 'logica.json'
$json = Get-Content -LiteralPath $rutaJson -Encoding UTF8 -Raw | ConvertFrom-Json
$versiones = @($json.versiones)
$ultima = $versiones | Sort-Object { [int]$_.version } -Descending | Select-Object -First 1
$sha = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
if ($ultima -and $ultima.sha256 -eq $sha) { Write-Host "Sin cambios: ya es la version $($ultima.version)." -ForegroundColor DarkGray; return }

$n = if ($ultima) { [int]$ultima.version + 1 } else { 1 }
$minimo = if ($LanzadorMinimo -gt 0) { $LanzadorMinimo } elseif ($ultima) { [int]$ultima.lanzadorMinimo } else { 1 }
$dir = Join-Path $PSScriptRoot "v$n"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $dir 'erdm-logica.ps1'), $bytes)

$nueva = [PSCustomObject]@{ version = $n; lanzadorMinimo = $minimo; archivo = "v$n/erdm-logica.ps1"; sha256 = $sha }
$json.versiones = @($versiones) + $nueva
[System.IO.File]::WriteAllText($rutaJson, (($json | ConvertTo-Json -Depth 6) + "`n"), $utf8SinBom)

if (-not $Mensaje) { $Mensaje = "Logica v$n" }
git add logica.json "v$n" erdm-logica.ps1
git commit -q -m "$Mensaje (v$n)"
if ($LASTEXITCODE -ne 0) { throw 'git commit falló' }

if ($SoloLocal) { Write-Host "v$n preparada (sin push)." -ForegroundColor DarkGray; return }
git push origin logica-pruebas
if ($LASTEXITCODE -ne 0) { throw 'git push falló' }
Write-Host "v$n publicada en el canal de pruebas. Pruébala y luego: .\publicar-logica.ps1 -Promover" -ForegroundColor Green
