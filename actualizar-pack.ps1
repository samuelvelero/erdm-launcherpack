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

# --- Red de seguridad 1: que no se cuele un binario en el repo ---
# --exclude-standard es imprescindible: sin el, "git ls-files --others"
# lista TAMBIEN los archivos ignorados, y esta comprobacion daba un falso
# positivo con los 165 .jar y .zip que .gitignore excluye correctamente,
# abortando la publicacion sin motivo alguno.
#
# Excepciones deliberadas: jars que SI viajan en el repo porque no existen en
# Modrinth y este repositorio es el unico sitio de donde los jugadores pueden
# bajarlos. Esta lista tiene que coincidir con las lineas "!" de .gitignore y
# .packwizignore; si se cambia el nombre de un jar hay que tocar los tres
# sitios, o la Red de seguridad 2 avisara de un huerfano.
$binariosPermitidos = @(
    'mods/itemswapperfabric1.0.0beta.2mc26.2git.4e23d0fdirty.jar',
    'mods/erdmdodge-0.1.1.jar'
)
$sospechosos = git ls-files --cached --others --exclude-standard |
    Where-Object {
        $_ -match '\.(jar|zip)$' -and
        $_ -notmatch 'bootstrap\.jar$' -and
        $binariosPermitidos -notcontains $_
    }
if ($sospechosos) {
    Write-Warning "Hay binarios sin ignorar; revisa .gitignore antes de subir:"
    $sospechosos | ForEach-Object { Write-Warning "  $_" }
    return
}

# --- Red de seguridad 2: todo lo indexado debe existir en el repositorio ---
# .packwizignore y .gitignore son listas independientes. Si un archivo entra al
# índice pero git lo ignora, GitHub devuelve 404 al descargarlo y el pack se
# rompe para todos los jugadores. Pasó con packwiz-installer.jar, que además el
# bootstrap auto-actualiza (el fallo aparecía semanas después, sin tocar nada).
$indexados = Select-String -Path 'index.toml' -Pattern '^file = "(.+?)"' |
    ForEach-Object { $_.Matches[0].Groups[1].Value }
# "git ls-files" a secas solo lista lo YA trackeado, y el "git add -A" ocurre
# despues (paso 3), asi que cualquier archivo nuevo disparaba la alarma. Lo que
# importa es lo que estara en el repo TRAS el add: trackeado + no ignorado.
$enRepo = [System.Collections.Generic.HashSet[string]]::new(
    [string[]](git ls-files --cached --others --exclude-standard),
    [System.StringComparer]::OrdinalIgnoreCase)
$huerfanos = $indexados | Where-Object { -not $enRepo.Contains($_) }
if ($huerfanos) {
    Write-Warning 'Estos archivos están en index.toml pero NO en el repositorio.'
    Write-Warning 'Cada uno sería un 404 para los jugadores. Añádelos a .packwizignore:'
    $huerfanos | ForEach-Object { Write-Warning "  $_" }
    return
}
Write-Host "      $($indexados.Count) archivos indexados, todos presentes en el repo"

# --- Red de seguridad 3: cada metafile debe apuntar a un .jar que existe ---
# Si actualizas un mod dejando caer el .jar nuevo a mano en vez de hacerlo desde
# el gestor de Prism, el metadato se queda con la version vieja: tu juegas con la
# nueva y publicas la antigua para todos, sin ningun aviso. Paso con DreamDisplays
# (jar 1.9.3, metadato 1.9.1).
$desfase = @()
foreach ($f in Get-ChildItem -Path $modsDir -Filter '*.pw.toml' -File) {
    $m = Select-String -Path $f.FullName -Pattern '^filename\s*=\s*[''"](.+?)[''"]' |
         Select-Object -First 1
    if ($m) {
        $nombre = $m.Matches[0].Groups[1].Value
        if (-not (Test-Path (Join-Path $modsDir $nombre))) {
            $desfase += "  $($f.Name) apunta a '$nombre', que no existe en mods/"
        }
    }
}
if ($desfase) {
    Write-Warning 'Hay metadatos desfasados respecto a los .jar de la carpeta.'
    Write-Warning 'Publicarias una version distinta de la que tu estas jugando:'
    $desfase | ForEach-Object { Write-Warning $_ }
    Write-Warning 'Actualiza el mod desde el gestor de Prism, o corrige el metadato con:'
    Write-Warning '  packwiz modrinth add --project-id <id> --version-id <id>'
    return
}
Write-Host "      metadatos y .jar coinciden"

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
