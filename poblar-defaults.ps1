<#
    poblar-defaults.ps1  —  recaptura config/** -> erdm-defaults/config/**
    según erdm-clasificacion.toml

    Copia a erdm-defaults/ todo lo que NO esté en [fuera]. Eso incluye
    tanto lo [forzado] como lo (implícito) semilla: la postura por
    defecto es que todo lo no clasificado es semilla, así que también
    viaja.

    Solo se corre a mano, cuando Samukis decide congelar un nuevo
    conjunto de defaults (normalmente vía
    actualizar-pack.ps1 -ActualizarDefaults). Cada instancia (-L / -H)
    tiene su propio erdm-defaults/: se corre en la de la versión que se
    quiera actualizar. NO se corre en cada
    publicación: si se corriera siempre, cualquier suciedad de una
    partida (timestamps, cachés sin clasificar) volvería a colarse en
    los defaults, que es el problema original que origina todo esto.

    Uso:
        .\poblar-defaults.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# ------------------------------------------------------------------
#  Parsear erdm-clasificacion.toml (formato: [fuera] / [forzado],
#  una ruta por línea relativa a config/, comentarios con #).
# ------------------------------------------------------------------
function Get-ClasificacionSet {
    param([string]$NombreSeccion)

    $ruta = Join-Path $PSScriptRoot 'erdm-clasificacion.toml'
    $resultado = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $enSeccion = $false

    foreach ($lineaCruda in Get-Content -LiteralPath $ruta -Encoding UTF8) {
        $linea = $lineaCruda.Trim()
        if ($linea -eq '' -or $linea.StartsWith('#')) { continue }
        if ($linea -match '^\[([a-z]+)\]$') {
            $enSeccion = ($Matches[1] -eq $NombreSeccion)
            continue
        }
        if ($enSeccion) { [void]$resultado.Add($linea) }
    }
    return $resultado
}

$fuera = Get-ClasificacionSet -NombreSeccion 'fuera'

$configDir = Join-Path $PSScriptRoot 'config'
$defaultsDir = Join-Path $PSScriptRoot 'erdm-defaults\config'

# ------------------------------------------------------------------
#  Fuente de verdad: recorrer config/ en disco, filtrando por
#  erdm-clasificacion.toml [fuera].
#
#  Antes (hasta el 13-sep-2026) usaba index.toml como filtro, porque
#  recorrer el disco a pelo colaba cachés de Xaero/Controlify que
#  .packwizignore excluía por otro lado. Pero config/ dejó de indexarse
#  directamente ese mismo día (cambio estructural: ahora se distribuye
#  erdm-defaults/, no config/), así que index.toml ya no tiene NINGUNA
#  entrada "config/..." de la que tirar. Se vuelve a recorrer el disco,
#  pero esta vez erdm-clasificacion.toml [fuera] absorbió también las
#  exclusiones que antes vivían en .packwizignore (ver el bloque
#  "Migradas desde .packwizignore" ahí) -- así que el filtro ya es
#  completo otra vez.
#
#  [fuera] puede nombrar un ARCHIVO o una CARPETA entera (p. ej.
#  "super_resolution"): Test-EstaFuera compara por coincidencia exacta
#  o por prefijo de carpeta.
# ------------------------------------------------------------------
function Test-EstaFuera {
    param([string]$RutaRelativa, [System.Collections.Generic.HashSet[string]]$Fuera)

    if ($Fuera.Contains($RutaRelativa)) { return $true }
    foreach ($entrada in $Fuera) {
        if ($RutaRelativa.StartsWith("$entrada/", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

if (-not (Test-Path $configDir)) { throw "No encuentro $configDir" }

if (Test-Path $defaultsDir) { Remove-Item -Path $defaultsDir -Recurse -Force }
New-Item -ItemType Directory -Path $defaultsDir -Force | Out-Null

$copiados = 0
$excluidos = 0
$sospechosos = [System.Collections.Generic.List[string]]::new()

Get-ChildItem -Path $configDir -Recurse -File | ForEach-Object {
    $rutaRelativa = $_.FullName.Substring($configDir.Length + 1) -replace '\\', '/'

    if (Test-EstaFuera -RutaRelativa $rutaRelativa -Fuera $fuera) {
        $excluidos++
        return
    }

    # Red de seguridad: nombres que HUELEN a caché/estado de máquina pero
    # no están en [fuera] -- probablemente alguien olvidó clasificarlos.
    # No bloquea la copia (semilla es el default seguro), solo avisa.
    if ($rutaRelativa -match '(?i)cache|\.lock$|\.dat$|fingerprint|_state\.json$') {
        $sospechosos.Add($rutaRelativa)
    }

    $destino = Join-Path $defaultsDir ($rutaRelativa -replace '/', '\')
    $carpetaDestino = Split-Path $destino -Parent
    if (-not (Test-Path $carpetaDestino)) {
        New-Item -ItemType Directory -Path $carpetaDestino -Force | Out-Null
    }
    Copy-Item -LiteralPath $_.FullName -Destination $destino -Force
    $copiados++
}

Write-Host "erdm-defaults/config/ actualizado: $copiados copiados, $excluidos excluidos (fuera)." -ForegroundColor Green

if ($sospechosos.Count -gt 0) {
    Write-Warning "Se copiaron $($sospechosos.Count) archivo(s) con nombre sospechoso (cache/lock/dat/fingerprint) que NO están en [fuera]. Revisar si de verdad son semilla:"
    $sospechosos | ForEach-Object { Write-Warning "  $_" }
}

# exit explícito: sin él, quien invoque este script con "&" y mire
# $LASTEXITCODE después puede llevarse el código de otra cosa que corrió
# antes en la sesión.
exit 0
