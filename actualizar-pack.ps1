<#
    actualizar-pack.ps1  —  publica los cambios del modpack ERDM-Official

    Ejecutar DESPUÉS de tocar mods/config/resourcepacks/shaders en Prism.
    Publica a: https://github.com/samuelvelero/erdm-launcherpack

    Uso:
        .\actualizar-pack.ps1
        .\actualizar-pack.ps1 -Mensaje "Añadido Create"
        .\actualizar-pack.ps1 -SoloLocal          # refresca sin subir a GitHub
        .\actualizar-pack.ps1 -ActualizarDefaults # además, recongela erdm-defaults/
                                                   # desde config/ (solo cuando se
                                                   # decide deliberadamente mejorar
                                                   # los defaults -- NO en cada
                                                   # publicación normal)

    IMPORTANTE: cierra Prism Launcher antes de ejecutarlo.
#>

[CmdletBinding()]
param(
    [string]$Mensaje,
    [switch]$SoloLocal,
    [switch]$ActualizarDefaults
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# PowerShell 5.1 decodifica la salida de procesos externos (git incluido) con
# [Console]::OutputEncoding, que por defecto es la codepage OEM del sistema,
# NO UTF-8. git emite UTF-8 real en stdout, así que cualquier nombre de
# archivo con acentos llega corrompido al pipeline (p. ej. "ó" se decodifica
# como "├│") aunque `-c core.quotepath=false` ya evite el escape octal. Sin
# esto, la comparación de las Redes de seguridad 1/2 contra $enRepo falla en
# falso para cualquier archivo no-ASCII, aunque esté presente de verdad --
# lo disparó "El Rincón de Minecraft.jpg/.json" (preset de AmbientFog).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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
Write-Host '[1/4] Sincronizando metadatos de Prism -> packwiz...' -ForegroundColor Cyan

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
#  Paso 1.5: reaplicar los bloques [option] de los perfiles
#
#  El paso anterior acaba de copiar mods/.index/*.pw.toml -> mods/,
#  y Prism no sabe nada de nuestro esquema de perfiles: esa copia
#  BORRA cualquier bloque [option] que hubiera en el .pw.toml de
#  destino. aplicar-perfiles.ps1 los reescribe a partir de
#  erdm-perfiles.txt -- es idempotente, así que no importa si ya
#  estaban o no.
# ------------------------------------------------------------------
Write-Host '[1.5/4] Reaplicando perfiles (Esencial / Gráficos Sofisticados)...' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'aplicar-perfiles.ps1')
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'aplicar-perfiles.ps1 encontró nombres de erdm-perfiles.txt sin metafile. Revisa el aviso de arriba antes de publicar.'
    return
}

if ($ActualizarDefaults) {
    Write-Host '      -ActualizarDefaults: recapturando config/ -> erdm-defaults/...' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'poblar-defaults.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'poblar-defaults.ps1 falló' }
}

# ------------------------------------------------------------------
#  Paso 2: regenerar el índice
# ------------------------------------------------------------------
Write-Host '[2/4] Regenerando index.toml...' -ForegroundColor Cyan
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
    'mods/erdmdodge-0.1.1.jar',
    'mods/hoofprint-1.3.026.2.jar',
    'mods/surveyor1.2.426.2.jar',
    'mods/spyglass_improvements-1.5.14-erdm.1+mc26.2+fabric.jar',
    'mods/erdmlauncherui-1.0.0.jar',
    'mods/desktoptooltips-1.0.0.jar',
    'resourcepacks/Visual Shulker Labels.zip'
)
# desktoptooltips-1.0.0.jar SÍ va aquí, aunque tenga metafile propio:
# esta lista es sobre qué .jar/.zip está bien que git rastree, no sobre
# si packwiz lo indexa por su cuenta. Su metafile (mode="url") apunta a
# ESTE mismo archivo en el repo, así que tiene que estar trackeado ---
# si no, sería un 404. (No confundir con la nota de .packwizignore, que
# es la lista distinta de "qué NO se indexa dos veces".)
$sospechosos = git -c core.quotepath=false ls-files --cached --others --exclude-standard |
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
# -Encoding UTF8 es obligatorio: index.toml lo escribe packwiz.exe sin BOM, y
# Select-String sin -Encoding lo lee con la codepage del sistema, corrompiendo
# cualquier ruta con acentos (p. ej. "Rincón" -> "RincÃ³n"). Sin esto, la
# comparación contra $enRepo (que sí decodifica bien vía git) falla en falso
# para cualquier archivo con un nombre no-ASCII, aunque esté presente de
# verdad -- lo disparó "El Rincón de Minecraft.jpg/.json" (preset de AmbientFog).
$indexados = Select-String -Path 'index.toml' -Pattern '^file = "(.+?)"' -Encoding UTF8 |
    ForEach-Object { $_.Matches[0].Groups[1].Value }

# --- Red de seguridad 2b: el estado local del jugador NUNCA se indexa ---
# Va ANTES del chequeo de huerfanos a proposito. Hoy estos archivos
# tambien dispararian ese chequeo (estan en el indice pero .gitignore los
# ignora, asi que salen como 404), pero ese mensaje habla de "anadelos a
# .packwizignore por un 404" y no dice lo importante: que el problema de
# verdad seria distribuir estado de UNA maquina a todos los jugadores.
#
# Son los tres archivos con los que cada jugador le habla al pre-launch
# desde SU maquina. Si entran al indice, la comunicacion se invierte: el
# pack le impone a todos lo que Samukis tenga en su instancia. El peor es
# erdm-reset-config.flag, que distribuido le borra la configuracion a
# TODOS los jugadores en cada sincronizacion.
#
# Ademas, apoyarse en el rebote del 404 es casualidad: si algun dia
# .gitignore dejara de ignorarlos, se distribuirian en SILENCIO.
# Paso de verdad el 13-sep-2026, con erdm-perfil.txt.
$estadoLocalJugador = @(
    'erdm-perfil.txt',
    'erdm-estado.json',
    'erdm-reset-config.flag',
    'erdm-perfil-aplicado.txt'
)
$estadoFiltrado = $indexados | Where-Object { $estadoLocalJugador -contains $_ }
if ($estadoFiltrado) {
    Write-Warning 'Hay estado LOCAL del jugador en el indice. Esto le pisaria su configuracion a todos:'
    $estadoFiltrado | ForEach-Object { Write-Warning "  $_" }
    Write-Warning 'Anadelos a .packwizignore (hay un bloque dedicado, busca "ESTADO LOCAL DEL JUGADOR").'
    return
}

# "git ls-files" a secas solo lista lo YA trackeado, y el "git add -A" ocurre
# despues (paso 3), asi que cualquier archivo nuevo disparaba la alarma. Lo que
# importa es lo que estara en el repo TRAS el add: trackeado + no ignorado.
$enRepo = [System.Collections.Generic.HashSet[string]]::new(
    [string[]](git -c core.quotepath=false ls-files --cached --others --exclude-standard),
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

# --- Red de seguridad 3b: todo metafile necesita un "side" valido ---
# packwiz-installer solo acepta 'client', 'server' o 'both'. Con
# cualquier otra cosa -- incluida la cadena VACIA -- rechaza el metafile
# entero y ABORTA TODA la sincronizacion: no es que falte ese mod, es
# que ningun jugador puede actualizar nada.
#
# Paso de verdad el 13-sep-2026: Prism genero "side = ''" al actualizar
# DreamDisplays a 1.10.0-preview.1 (una version alpha cuyo metadata en
# Modrinth no declara el lado). Las cinco redes de seguridad de entonces
# lo dieron por bueno -- ninguna miraba este campo -- y solo se detecto
# al ensayar el pack con el instalador real contra "packwiz serve".
# De ahi esta comprobacion: es gratis y cubre un fallo que rompe a todos.
$ladosValidos = @('client', 'server', 'both')
$ladosMalos = @()
foreach ($carpeta in @('mods', 'resourcepacks', 'shaderpacks')) {
    $rutaCarpeta = Join-Path $PSScriptRoot $carpeta
    if (-not (Test-Path $rutaCarpeta)) { continue }
    foreach ($f in Get-ChildItem -Path $rutaCarpeta -Filter '*.pw.toml' -File) {
        $m = Select-String -Path $f.FullName -Pattern '^side\s*=\s*[''"](.*)[''"]' | Select-Object -First 1
        if (-not $m) { continue }   # sin campo "side" es valido: packwiz asume 'both'
        $lado = $m.Matches[0].Groups[1].Value
        if ($ladosValidos -notcontains $lado) {
            $ladosMalos += "  $carpeta\$($f.Name): side = '$lado'"
        }
    }
}
if ($ladosMalos) {
    Write-Warning 'Hay metafiles con un "side" que packwiz-installer rechaza.'
    Write-Warning 'Esto no rompe solo ese mod: ABORTA la sincronizacion entera para todos.'
    $ladosMalos | ForEach-Object { Write-Warning $_ }
    Write-Warning "Valores validos: client, server, both (o quitar la linea). Corrigelo en mods\ Y en mods\.index\."
    return
}
Write-Host "      todos los 'side' son validos"

# --- Red de seguridad 4: todo .jar en mods/ debe tener metafile o ser
#     una excepción declarada ---
# Así se descubrieron controlify, hoofprint, surveyor y desktoptooltips
# en septiembre de 2026: llevaban semanas en mods/ sin metafile, y como
# "/mods/*.jar" está en .packwizignore, packwiz los ignoraba en
# silencio -- ningún jugador los recibía y nada avisaba de ello.
$excepcionesConocidas = $binariosPermitidos | ForEach-Object { Split-Path $_ -Leaf }
$huerfanosDeMetafile = @()
foreach ($jar in Get-ChildItem -Path $modsDir -Filter '*.jar' -File) {
    $tieneMetafile = Get-ChildItem -Path $modsDir -Filter '*.pw.toml' -File |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Encoding UTF8 -Raw) -match [regex]::Escape($jar.Name) }
    if (-not $tieneMetafile -and $excepcionesConocidas -notcontains $jar.Name) {
        $huerfanosDeMetafile += $jar.Name
    }
}
if ($huerfanosDeMetafile) {
    Write-Warning 'Hay .jar en mods/ sin metafile y sin declarar como excepción:'
    $huerfanosDeMetafile | ForEach-Object { Write-Warning "  $_" }
    Write-Warning 'Nadie los va a recibir. Añádelos con "packwiz modrinth add", o si son'
    Write-Warning 'un build propio, decláralos en $binariosPermitidos (arriba en este script)'
    Write-Warning 'y añade la excepción "!/mods/<nombre>.jar" en .gitignore y .packwizignore.'
    return
}
Write-Host "      sin .jar huérfanos"

# --- Red de seguridad 5: TST2 es el playground de Samukis y se
#     desordena por diseño -- este chequeo se repite en cada
#     publicación, no es un saneamiento de una sola vez. ---
$problemasDeOrden = @()

$disabled = Get-ChildItem -Path $PSScriptRoot -Recurse -Filter '*.disabled' -File -ErrorAction SilentlyContinue
if ($disabled) {
    $problemasDeOrden += "$($disabled.Count) archivo(s) .disabled sueltos (revisa mods/ y decide si se borran o se reactivan)"
}

foreach ($carpeta in @('resourcepacks', 'shaderpacks')) {
    $rutaCarpeta = Join-Path $PSScriptRoot $carpeta
    if (-not (Test-Path $rutaCarpeta)) { continue }
    foreach ($f in Get-ChildItem -Path $rutaCarpeta -Filter '*.pw.toml' -File) {
        $m = Select-String -Path $f.FullName -Pattern '^filename\s*=\s*[''"](.+?)[''"]' | Select-Object -First 1
        if ($m -and -not (Test-Path (Join-Path $rutaCarpeta $m.Matches[0].Groups[1].Value))) {
            $problemasDeOrden += "$carpeta\$($f.Name) apunta a un archivo que no existe"
        }
    }
}

if ($problemasDeOrden) {
    Write-Warning 'TST2 tiene desorden pendiente de revisar antes de publicar:'
    $problemasDeOrden | ForEach-Object { Write-Warning "  $_" }
    return
}
Write-Host "      TST2 en orden"

# ------------------------------------------------------------------
#  Paso 3: publicar
# ------------------------------------------------------------------
if ($SoloLocal) {
    Write-Host '[4/4] -SoloLocal: no se sube nada a GitHub.' -ForegroundColor DarkGray
    git status --short
    return
}

Write-Host '[4/4] Publicando en GitHub...' -ForegroundColor Cyan

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
