<#
    actualizar-pack.ps1  —  publica los cambios del modpack ERDM-Official

    Ejecutar DESPUÉS de tocar mods/config/resourcepacks/shaders en Prism.
    Publica a: https://github.com/samuelvelero/erdm-launcherpack

    Uso:
        .\actualizar-pack.ps1
        .\actualizar-pack.ps1 -Mensaje "Añadido Create"
        .\actualizar-pack.ps1 -SoloLocal      # refresca sin subir a GitHub

    IMPORTANTE: cierra Prism Launcher antes de ejecutarlo.
#>

[CmdletBinding()]
param(
    [string]$Mensaje,
    [switch]$SoloLocal
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$packwiz = Join-Path $PSScriptRoot '..\..\..\..\tools\packwiz.exe'
if (-not (Test-Path $packwiz)) {
    throw "No encuentro packwiz.exe en: $packwiz"
}

# --- Aviso si Prism está abierto: reescribiría instance.cfg al cerrarse ---
if (Get-Process -Name 'prismlauncher' -ErrorAction SilentlyContinue) {
    Write-Warning 'Prism Launcher está abierto. Ciérralo antes de continuar.'
    return
}

# ------------------------------------------------------------------
#  Paso 1: sincronizar los metadatos de Prism con los de packwiz
#
#  Prism escribe sus .pw.toml en "mods/.index/", pero packwiz-installer
#  deduce el destino del .jar a partir de dónde está el metafile. Si se
#  indexan desde ".index", los mods se instalan en "mods/.index/" y el
#  juego arranca SIN NINGÚN MOD. Por eso la copia autoritativa vive en
#  "mods/" y esta función mantiene las dos en sincronía.
# ------------------------------------------------------------------
Write-Host '[1/3] Sincronizando metadatos de Prism -> packwiz...' -ForegroundColor Cyan

$indexDir = Join-Path $PSScriptRoot 'mods\.index'
$modsDir  = Join-Path $PSScriptRoot 'mods'

if (-not (Test-Path $indexDir)) { throw "No existe $indexDir" }

$enIndex = @(Get-ChildItem -Path $indexDir -Filter '*.pw.toml' -File)
$enMods  = @(Get-ChildItem -Path $modsDir  -Filter '*.pw.toml' -File)

# Copiar/actualizar los que Prism conoce
$nuevos = 0
foreach ($f in $enIndex) {
    $destino = Join-Path $modsDir $f.Name
    if ((-not (Test-Path $destino)) -or
        ((Get-FileHash $f.FullName).Hash -ne (Get-FileHash $destino).Hash)) {
        Copy-Item $f.FullName $destino -Force
        Write-Host "      + $($f.Name)" -ForegroundColor Green
        $nuevos++
    }
}

# Borrar los que ya no existen en Prism (mods eliminados)
$nombresIndex = $enIndex.Name
$borrados = 0
foreach ($f in $enMods) {
    if ($nombresIndex -notcontains $f.Name) {
        Remove-Item $f.FullName -Force
        Write-Host "      - $($f.Name)" -ForegroundColor Yellow
        $borrados++
    }
}

Write-Host "      $($enIndex.Count) mods | $nuevos actualizados | $borrados eliminados"

# ------------------------------------------------------------------
#  Paso 2: regenerar el índice
# ------------------------------------------------------------------
Write-Host '[2/3] Regenerando index.toml...' -ForegroundColor Cyan
& $packwiz refresh
if ($LASTEXITCODE -ne 0) { throw "packwiz refresh falló (código $LASTEXITCODE)" }

$entradas = (Select-String -Path 'index.toml' -Pattern '^\[\[files\]\]' -AllMatches).Count
Write-Host "      $entradas archivos en el índice"

# --- Red de seguridad: que no se cuele un binario en el repo ---
$sospechosos = git ls-files --others --cached |
    Where-Object { $_ -match '\.(jar|zip)$' -and $_ -notmatch 'bootstrap\.jar$' }
if ($sospechosos) {
    Write-Warning "Hay binarios sin ignorar; revisa .gitignore antes de subir:"
    $sospechosos | ForEach-Object { Write-Warning "  $_" }
    return
}

# ------------------------------------------------------------------
#  Paso 3: publicar
# ------------------------------------------------------------------
if ($SoloLocal) {
    Write-Host '[3/3] -SoloLocal: no se sube nada a GitHub.' -ForegroundColor DarkGray
    git status --short
    return
}

Write-Host '[3/3] Publicando en GitHub...' -ForegroundColor Cyan

git add -A
if (-not (git diff --cached --name-only)) {
    Write-Host '      Sin cambios que publicar.' -ForegroundColor DarkGray
    return
}

git diff --cached --stat

if (-not $Mensaje) {
    $Mensaje = "Actualizar modpack - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
}
git commit -m $Mensaje
if ($LASTEXITCODE -ne 0) { throw "git commit falló" }

git push
if ($LASTEXITCODE -ne 0) { throw "git push falló" }

Write-Host ''
Write-Host 'Listo. Los jugadores recibirán la actualización en su próximo arranque.' -ForegroundColor Green
Write-Host 'Nota: raw.githubusercontent.com cachea unos minutos.' -ForegroundColor DarkGray
