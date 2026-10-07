<#
    erdm-logica.ps1  —  LÓGICA del launcher del lado del jugador (se auto-actualiza)

    Esto NO viaja en el .exe: lo descarga el lanzador (erdm-launcher.ps1, fijo)
    desde la rama `logica` del repo del pack. Contrato con el lanzador (API 1):
    recibe -Fase Pre|Post y -Raiz <minecraft>, deja erdm-pack-url.txt en Pre y
    sale con 0 si todo fue bien. Para cambiarla: publicar-logica.ps1, sin instalador.

    El lanzador lo invoca en dos momentos:

        -Fase Pre    ANTES del sync de packwiz
        -Fase Post   DESPUÉS del sync de packwiz

    Desde el 1.3.0 hay DOS modpacks independientes, uno por rama del repo:
        esencial               ->  rama main
        graficos-sofisticados  ->  rama sofisticado
    Ya no hay mods opcionales ni erdm-perfiles.txt.

    -Fase Pre:
        0. Rescata instalaciones 1.1.0-1.1.2 (borra la .voxy incompleta
           que repartieron por error), una sola vez.
        1. Si no existe erdm-perfil.txt (primer arranque), muestra la
           ventana de elegir versión del modpack y lo escribe.
        2. Escribe erdm-pack-url.txt con la URL del pack elegido; de ahí
           la lee packwiz-sync.bat.
        3. Si el pack elegido no es el que hay instalado
           (erdm-pack-aplicado.txt), lo deja todo listo para que packwiz
           instale el otro desde cero: borra mods/, los resourcepacks y
           shaders de los dos packs (nunca los que puso el jugador),
           erdm-defaults/ y packwiz.json.

    -Fase Post:
        0a. Mantiene desactivados los mods del pack que el jugador desactivo.
        0. Aplica las sustituciones de IP de erdm-servidor.json a servers.dat.
        1. Si hay un erdm-reset-config.flag, borra la config gestionada
           por el pack (para que se regenere limpia) y borra el flag.
        2. Siembra config/ desde erdm-defaults/config/, sin pisar nada
           que el jugador haya personalizado.

    No publica nada, no toca git. Solo lee/escribe en el disco del
    jugador. Viaja en el instalador (.exe), NO en el índice de packwiz
    — mismo motivo que packwiz-sync.bat: packwiz podría reescribirlo
    mientras se está ejecutando.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Pre', 'Post')]
    [string]$Fase,

    # Carpeta minecraft de la instancia. La pasa erdm-launcher.ps1 (el lanzador);
    # esta logica ya no vive ahi, vive en minecrafterdm-logica.
    [Parameter(Mandatory)]
    [string]$Raiz
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $Raiz

$rutaPerfil       = Join-Path $Raiz 'erdm-perfil.txt'
# Qué pack está instalado de verdad. Distinto de erdm-perfil.txt (el
# elegido, que el botón del juego puede cambiar en cualquier momento):
# si no coinciden, toca cambiar de pack.
$rutaPackAplicado = Join-Path $Raiz 'erdm-pack-aplicado.txt'
# La URL que usará packwiz-sync.bat. La decide este script para que el
# .bat no tenga que saber nada de perfiles.
$rutaPackUrl      = Join-Path $Raiz 'erdm-pack-url.txt'
$rutaPackwizJson  = Join-Path $Raiz 'packwiz.json'
$rutaResetFlag    = Join-Path $Raiz 'erdm-reset-config.flag'
$rutaEstado       = Join-Path $Raiz 'erdm-estado.json'
$rutaDefaults     = Join-Path $Raiz 'erdm-defaults\config'
$rutaConfig       = Join-Path $Raiz 'config'
# Marca de que ya se limpió la caché de Voxy que repartieron los
# instaladores 1.1.0-1.1.2. NO viaja en el payload (ver build-payload.ps1):
# si viajara, el rescate no correría en la máquina de nadie.
$rutaVoxyReparada = Join-Path $Raiz 'erdm-voxy-reparada.flag'
# Mods del pack que el jugador desactivo desde Prism (ver Restore-ModsDesactivados).
$rutaDesactivados = Join-Path $Raiz 'erdm-desactivados.txt'

# Carpeta (sin "/pack.toml") de cada pack. Las variables de entorno solo
# sirven para probar contra "packwiz serve" en local; ningún jugador las
# tiene definidas.
$basesPack = [ordered]@{
    'esencial'              = if ($env:ERDM_URL_ESENCIAL) { $env:ERDM_URL_ESENCIAL } else { 'https://raw.githubusercontent.com/samuelvelero/erdm-launcherpack/main' }
    'graficos-sofisticados' = if ($env:ERDM_URL_SOFISTICADO) { $env:ERDM_URL_SOFISTICADO } else { 'https://raw.githubusercontent.com/samuelvelero/erdm-launcherpack/sofisticado' }
}

# PowerShell 5.1 sobre .NET antiguo puede no ofrecer TLS 1.2, y GitHub
# no acepta otra cosa.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$utf8SinBom = New-Object System.Text.UTF8Encoding $false

function Write-TextoSinBom {
    param([string]$Ruta, [string]$Texto)
    [System.IO.File]::WriteAllText($Ruta, $Texto, $utf8SinBom)
}

function Read-TextoRecortado {
    param([string]$Ruta)
    if (-not (Test-Path -LiteralPath $Ruta)) { return '' }
    return ([System.IO.File]::ReadAllText($Ruta)).Trim()
}

# ------------------------------------------------------------------
#  Rescate de las instalaciones 1.1.0 - 1.1.2 (14-sep-2026)
#
#  Esos tres instaladores repartieron, sin querer, la base de datos de
#  LODs de Voxy (.voxy, 550 MB) de la máquina de Samukis: build-payload.ps1
#  excluía Distant_Horizons_server_data pero nadie añadió .voxy cuando
#  Voxy sustituyó a DH. Copiada archivo a archivo por robocopy desde una
#  RocksDB/LMDB, llega incompleta, y Voxy aborta el ingreso al servidor:
#
#      IllegalStateException: Block entry not ordered
#      at me.cortex.voxy.common.world.other.Mapper.loadFromStorage
#
#  (Ojo: Voxy SÍ tolera que se quiten mods -- en ese caso reasigna el ID
#  a un bloque aleatorio existente para no dejar huecos. Lo que no
#  sobrevive es que falten registros enteros, que es este caso.)
#
#  Desde 1.1.3 el instalador ya no la reparte, pero eso no arregla a
#  quien ya la tiene en disco: packwiz no gestiona .voxy, así que se
#  quedaría crasheando para siempre. Y este script solo viaja en el
#  .exe, de modo que el rescate llega al actualizar el launcher.
#
#  Se borra UNA sola vez, con marca propia. Es dato derivado: Voxy lo
#  regenera jugando, así que en una instalación sana el coste es volver
#  a renderizar el terreno lejano, no perder nada.
#
#  ⚠️ CADUCIDAD: esta función tiene fecha de baja. La marca es "¿ya se
#  limpió ESTA instalación alguna vez?", no "¿esta instalación viene de
#  un instalador roto?" -- no hay forma de distinguir ambos casos desde
#  aquí. Hoy es inofensivo (nadie ha tenido tiempo de acumular .voxy
#  legítimo en un 1.1.3+ sano). Pero si esto sigue en el código dentro
#  de meses, cualquier jugador que actualice el .exe por CUALQUIER OTRO
#  motivo -- y que para entonces lleve semanas jugando sano, con un
#  .voxy legítimo de varios GB -- se lo borraría una vez sin necesitarlo.
#  Quitar esta función (y su llamada en Invoke-FasePre) cuando se pueda
#  asumir que ya nadie sigue en 1.1.0-1.1.2.
# ------------------------------------------------------------------
function Repair-VoxyDistribuida {
    if (Test-Path $rutaVoxyReparada) { return }

    foreach ($cache in @('.voxy', '.vss')) {
        $ruta = Join-Path $Raiz $cache
        if (-not (Test-Path $ruta)) { continue }
        try {
            Remove-Item -LiteralPath $ruta -Recurse -Force
            Write-Host "[ERDM] Eliminada la cache de Voxy repartida por error ($cache); se regenera jugando."
        } catch {
            # Sin marca: se reintenta en el proximo arranque. Pasa si el
            # juego quedo abierto (RocksDB mantiene el fichero bloqueado).
            Write-Warning "[ERDM] No se pudo borrar '$cache': $($_.Exception.Message). Se reintentara."
            return
        }
    }

    Write-TextoSinBom -Ruta $rutaVoxyReparada -Texto "reparado $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
}

# ------------------------------------------------------------------
#  Respetar los mods del pack que el jugador desactiva (desde 1.4.0, logica v2)
#
#  Prism desactiva un mod renombrando X.jar -> X.jar.disabled. Pero packwiz ve
#  que X.jar falta y lo vuelve a bajar en el siguiente arranque, reactivandolo
#  (y dejando los dos archivos). Aqui se recuerda la eleccion del jugador:
#
#    Pre : mira packwiz.json y el disco. Si falta el .jar y existe el
#          .jar.disabled, el jugador lo desactivo -> se anota en
#          erdm-desactivados.txt ("mods/<id>.pw.toml|<archivo>.jar"). Si el .jar
#          existe sin .disabled, lo reactivo (o nunca lo toco) -> se quita.
#    Post: tras el sync, los anotados se vuelven a dejar desactivados.
#
#  Solo aplica a mods con metafile (los de Modrinth). Los jar propios del pack
#  (erdmlauncherui, erdmdodge...) no son desactivables: siempre se restauran.
#  Las librerias de $modsProtegidos tampoco: sin ellas el juego ni arranca,
#  asi que se restauran y se avisa. packwiz volvera a bajar estos mods en cada
#  arranque (unos pocos MB); es el precio de que el jugador pueda desactivarlos.
# ------------------------------------------------------------------
$modsProtegidos = @(
    'fabric-api', 'fabric-language-kotlin', 'balm', 'cloth-config', 'craterlib',
    'creativecore', 'forge-config-api-port', 'fzzy-config', 'malilib',
    'placeholder-api', 'player-animation-library', 'puzzles-lib', 'searchables', 'yacl',
    'sodium', 'voxy', 'voxy-extra', 'voxy-worldgen', 'voxy-server-side'
)

function Read-Desactivados {
    $estado = [ordered]@{}
    if (Test-Path -LiteralPath $rutaDesactivados) {
        foreach ($linea in [System.IO.File]::ReadAllLines($rutaDesactivados)) {
            $partes = $linea.Split('|')
            if ($partes.Count -eq 2 -and $partes[0] -match '^mods/.+\.pw\.toml$') { $estado[$partes[0]] = $partes[1] }
        }
    }
    return $estado
}

function Write-Desactivados {
    param($Estado)
    if ($Estado.Count -eq 0) {
        if (Test-Path -LiteralPath $rutaDesactivados) { Remove-Item -LiteralPath $rutaDesactivados -Force }
        return
    }
    $lineas = $Estado.Keys | ForEach-Object { "$_|$($Estado[$_])" }
    [System.IO.File]::WriteAllLines($rutaDesactivados, [string[]]$lineas, $utf8SinBom)
}

function Get-ManifiestoPackwiz {
    if (-not (Test-Path -LiteralPath $rutaPackwizJson)) { return $null }
    try { return (Get-Content -LiteralPath $rutaPackwizJson -Encoding UTF8 -Raw | ConvertFrom-Json) } catch { return $null }
}

function Sync-DesactivadosDesdeDisco {
    $manifiesto = Get-ManifiestoPackwiz
    if (-not $manifiesto -or -not $manifiesto.cachedFiles) { return }
    $estado = Read-Desactivados
    $antes = ($estado.Keys | ForEach-Object { "$_|$($estado[$_])" }) -join ';'
    foreach ($entrada in $manifiesto.cachedFiles.PSObject.Properties) {
        if ($entrada.Name -notmatch '^mods/.+\.pw\.toml$') { continue }
        $loc = $entrada.Value.cachedLocation
        if (-not $loc) { continue }
        $jar = Join-Path $Raiz ($loc -replace '/', '\')
        $hayJar = Test-Path -LiteralPath $jar
        $hayDis = Test-Path -LiteralPath "$jar.disabled"
        if (-not $hayJar -and $hayDis) { $estado[$entrada.Name] = (Split-Path $jar -Leaf) }
        elseif ($hayJar -and -not $hayDis -and $estado.Contains($entrada.Name)) { $estado.Remove($entrada.Name) }
    }
    $despues = ($estado.Keys | ForEach-Object { "$_|$($estado[$_])" }) -join ';'
    if ($antes -ne $despues) { Write-Desactivados $estado }
}

function Restore-ModsDesactivados {
    $estado = Read-Desactivados
    if ($estado.Count -eq 0) { return }
    $manifiesto = Get-ManifiestoPackwiz
    if (-not $manifiesto -or -not $manifiesto.cachedFiles) { return }

    $mantenidos = 0
    foreach ($id in @($estado.Keys)) {
        $nombre = $id -replace '^mods/', '' -replace '\.pw\.toml$', ''
        $entrada = $manifiesto.cachedFiles.PSObject.Properties[$id]
        if (-not $entrada -or -not $entrada.Value.cachedLocation) { $estado.Remove($id); continue }   # el pack ya no lo trae

        $jar = Join-Path $Raiz ($entrada.Value.cachedLocation -replace '/', '\')
        $viejo = Join-Path (Split-Path $jar -Parent) $estado[$id]

        if ($modsProtegidos -contains $nombre) {
            Write-Host "[ERDM] '$nombre' es una libreria esencial del pack: no se puede desactivar, se mantiene activo."
            foreach ($dis in @("$jar.disabled", "$viejo.disabled")) { if (Test-Path -LiteralPath $dis) { Remove-Item -LiteralPath $dis -Force } }
            $estado.Remove($id); continue
        }

        # packwiz acaba de volver a bajar el .jar: dejarlo desactivado otra vez.
        if (Test-Path -LiteralPath $jar) {
            if (Test-Path -LiteralPath "$jar.disabled") { Remove-Item -LiteralPath $jar -Force }
            else { Move-Item -LiteralPath $jar -Destination "$jar.disabled" -Force }
        }
        # Si el pack actualizo el mod a otro archivo, la copia desactivada vieja sobra.
        if ($viejo -ne $jar -and (Test-Path -LiteralPath "$viejo.disabled")) { Remove-Item -LiteralPath "$viejo.disabled" -Force }
        $estado[$id] = (Split-Path $jar -Leaf)
        $mantenidos++
    }
    Write-Desactivados $estado
    if ($mantenidos -gt 0) { Write-Host "[ERDM] $mantenidos mod(s) del pack se mantienen desactivados, como los dejaste." }
}

# ==================================================================
#  FASE PRE
# ==================================================================
function Invoke-FasePre {

    # --- 0) Rescate de las instalaciones 1.1.0 - 1.1.2 --------------
    Repair-VoxyDistribuida

    # --- 0b) Anotar los mods del pack que el jugador desactivo ------
    Sync-DesactivadosDesdeDisco

    # --- 1) Elegir versión (solo la primera vez) --------------------
    if (-not (Test-Path $rutaPerfil)) {
        Write-Host '[ERDM] Primer arranque: pidiendo elegir versión del modpack...'
        $elegido = Show-SelectorPerfil
        Write-TextoSinBom -Ruta $rutaPerfil -Texto $elegido
        Write-Host "[ERDM] Versión elegida: $elegido"
    }

    $perfil = Read-TextoRecortado $rutaPerfil
    if (-not $basesPack.Contains($perfil)) {
        Write-Warning "erdm-perfil.txt tiene un valor raro ('$perfil'); se asume 'esencial'."
        $perfil = 'esencial'
        Write-TextoSinBom -Ruta $rutaPerfil -Texto $perfil
    }

    # Restos del sistema de perfiles anterior (1.1.0 - 1.2.0). Ya no los
    # lee nadie; se quitan para que no confundan a quien mire la carpeta.
    foreach ($viejo in @('erdm-perfiles.txt', 'erdm-perfil-aplicado.txt')) {
        $ruta = Join-Path $Raiz $viejo
        if (Test-Path -LiteralPath $ruta) { Remove-Item -LiteralPath $ruta -Force -ErrorAction SilentlyContinue }
    }

    # --- 2) URL del pack para packwiz-sync.bat -----------------------
    Write-TextoSinBom -Ruta $rutaPackUrl -Texto "$($basesPack[$perfil])/pack.toml"

    # --- 3) Cambio de pack, si toca --------------------------------
    # Sin erdm-pack-aplicado.txt también toca: es una instalación que
    # viene del sistema anterior (1.2.0 o antes), con mods opcionales a
    # medio sembrar en packwiz.json. Empezar de cero es lo único seguro.
    $aplicado = Read-TextoRecortado $rutaPackAplicado
    if ($aplicado -eq $perfil) {
        Write-Host "[ERDM] Versión '$perfil' ya instalada."
        return
    }

    $desde = if ($aplicado) { "'$aplicado'" } else { 'la instalación anterior' }
    Write-Host "[ERDM] Cambiando de $desde a '$perfil': se borran los mods y se descarga el pack completo. Puede tardar unos minutos."
    if (Invoke-CambioDePack) {
        Write-TextoSinBom -Ruta $rutaPackAplicado -Texto $perfil
    }
}

# ------------------------------------------------------------------
#  Cambio de pack (desde 1.3.0)
#
#  Deja la instancia como si nunca hubiera tenido ningún pack, para que
#  packwiz instale el nuevo desde cero. Es a propósito lo más bruto
#  posible: el sistema anterior intentaba respetar lo que había en disco
#  y cada caso raro (archivos del instalador sin "cachedLocation",
#  opciones heredadas, copias .duplicate de Prism...) era un bug nuevo.
#
#  Qué se borra:
#    - mods/ entera. El jugador no pone mods a mano en este launcher.
#    - resourcepacks/ y shaderpacks/: SOLO los archivos que aparecen en
#      cualquiera de los DOS packs. Los que se bajó el jugador por su
#      cuenta no están en ninguno, así que se quedan. Se borran los de
#      los dos packs (no solo los del anterior) porque así no hace falta
#      saber cuál era el anterior -- p. ej. al venir del 1.2.0 -- y lo
#      que sea del pack nuevo packwiz lo vuelve a bajar enseguida.
#    - erdm-defaults/: es contenido del pack, packwiz lo vuelve a bajar.
#      Si no, se quedarían defaults de mods que el pack nuevo no tiene.
#    - packwiz.json, lo último: es lo que convierte la siguiente
#      sincronización en una instalación desde cero.
#
#  Nunca toca config/, saves/, options.txt ni nada del jugador.
#
#  Devuelve $false si algo no se pudo borrar (p. ej. un archivo
#  bloqueado). En ese caso packwiz.json se conserva -- así packwiz aún
#  puede quitar lo que él instaló -- y no se marca el pack como aplicado,
#  de modo que el cambio se reintenta en el siguiente arranque.
# ------------------------------------------------------------------
function Invoke-CambioDePack {
    $todoBorrado = $true

    # Lista de resourcepacks/shaders de los dos packs, ANTES de borrar
    # nada: si no hay conexión, packwiz tampoco podrá bajar el pack nuevo,
    # así que mejor no tocar nada y reintentar en el próximo arranque.
    try {
        $archivosDePacks = @(Get-ArchivosVisualesDeLosPacks)
    } catch {
        Write-Warning "[ERDM] No se pudo leer la lista de los packs ($($_.Exception.Message)). Se reintentará el cambio en el próximo arranque."
        return $false
    }
    # Refuerzo: lo que packwiz dice haber instalado en esas carpetas,
    # por si algún archivo ya no está en ninguno de los dos packs.
    $archivosDePacks += @(Get-ArchivosVisualesSegunPackwiz)

    $rutaMods = Join-Path $Raiz 'mods'
    if (Test-Path -LiteralPath $rutaMods) {
        try {
            Remove-Item -LiteralPath $rutaMods -Recurse -Force
            Write-Host '[ERDM] mods/ borrada.'
        } catch {
            Write-Warning "[ERDM] No se pudo borrar mods/ entera: $($_.Exception.Message)"
            $todoBorrado = $false
        }
    }

    $borrados = 0
    foreach ($relativa in ($archivosDePacks | Sort-Object -Unique)) {
        $ruta = Join-Path $Raiz ($relativa -replace '/', '\')
        if (-not (Test-Path -LiteralPath $ruta)) { continue }
        try {
            Remove-Item -LiteralPath $ruta -Force
            $borrados++
        } catch {
            Write-Warning "[ERDM] No se pudo borrar '$relativa': $($_.Exception.Message)"
            $todoBorrado = $false
        }
    }
    Write-Host "[ERDM] $borrados resourcepack(s)/shader(s) del pack borrados; los tuyos se quedan."

    $rutaErdmDefaults = Join-Path $Raiz 'erdm-defaults'
    if (Test-Path -LiteralPath $rutaErdmDefaults) {
        try { Remove-Item -LiteralPath $rutaErdmDefaults -Recurse -Force }
        catch {
            Write-Warning "[ERDM] No se pudo borrar erdm-defaults/: $($_.Exception.Message)"
            $todoBorrado = $false
        }
    }

    if (-not $todoBorrado) {
        Write-Warning '[ERDM] El cambio de versión quedó a medias; se reintentará en el próximo arranque.'
        return $false
    }

    if (Test-Path -LiteralPath $rutaPackwizJson) {
        Remove-Item -LiteralPath $rutaPackwizJson -Force
    }
    # Empezar de cero tambien con lo desactivado: esas elecciones eran del pack anterior.
    if (Test-Path -LiteralPath $rutaDesactivados) { Remove-Item -LiteralPath $rutaDesactivados -Force }
    return $true
}

# Rutas relativas ("resourcepacks/<archivo>") de todos los resourcepacks y
# shaders que declaran los dos packs, leídas de su index.toml publicado.
# Lanza una excepción si algún pack no responde.
function Get-ArchivosVisualesDeLosPacks {
    $resultado = [System.Collections.Generic.List[string]]::new()
    foreach ($base in $basesPack.Values) {
        $indice = (Invoke-WebRequest -Uri "$base/index.toml" -TimeoutSec 10 -UseBasicParsing).Content
        # Cada entrada: [[files]] / file = "..." / hash = "..." / metafile = true
        foreach ($bloque in ($indice -split '\[\[files\]\]')) {
            if ($bloque -notmatch '(?m)^file\s*=\s*"(.+?)"') { continue }
            $ruta = $Matches[1]
            if ($ruta -notmatch '^(resourcepacks|shaderpacks)/') { continue }
            $carpeta = $Matches[1]

            if ($bloque -match '(?m)^metafile\s*=\s*true') {
                # El nombre del .zip solo lo sabe el metafile.
                $metafile = (Invoke-WebRequest -Uri "$base/$($ruta -replace ' ', '%20')" -TimeoutSec 10 -UseBasicParsing).Content
                if ($metafile -match "(?m)^filename\s*=\s*['""](.+?)['""]") {
                    $resultado.Add("$carpeta/$($Matches[1])")
                }
            } else {
                # Archivo directo (p. ej. "Visual Shulker Labels.zip").
                $resultado.Add($ruta)
            }
        }
    }
    return $resultado
}

function Get-ArchivosVisualesSegunPackwiz {
    if (-not (Test-Path -LiteralPath $rutaPackwizJson)) { return @() }
    try {
        $manifiesto = Get-Content -LiteralPath $rutaPackwizJson -Encoding UTF8 -Raw | ConvertFrom-Json
    } catch { return @() }
    if (-not $manifiesto.cachedFiles) { return @() }
    return @($manifiesto.cachedFiles.PSObject.Properties |
        ForEach-Object { $_.Value.cachedLocation } |
        Where-Object { $_ -and $_ -match '^(resourcepacks|shaderpacks)/' })
}

# ------------------------------------------------------------------
#  Ventana de selección de versión — WinForms, dos tarjetas.
#  Bloquea el pre-launch hasta que el jugador elige; timeout propio
#  de 60s -> Esencial, para no dejar a Prism colgado si el jugador
#  se fue sin más.
# ------------------------------------------------------------------
function Show-SelectorPerfil {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # OJO con el scope: estas dos van con "$script:" a propósito, y hay que
    # declararlas así TAMBIÉN aquí, no solo donde se asignan.
    #
    # Los scriptblocks de los eventos (Add_Click, Add_Tick) corren en su
    # propio scope hijo, así que si escriben "$script:resultado" y aquí la
    # variable se declara local ("$resultado"), son DOS variables distintas:
    # el botón escribe una y el "return" devuelve la otra.
    #
    # Los dos bugs que causó, encontrados en el primer arranque real
    # (13-sep-2026):
    #  - La ventana se cerraba sola en 1 segundo: "$script:segundosRestantes"
    #    no existía, así que "$null - 1" daba -1, y "-1 -le 0" disparaba el
    #    cierre por timeout en el primer tick del timer.
    #  - Y aunque hubiera dado tiempo a pulsar, "return $resultado" devolvía
    #    la local intacta: siempre 'esencial', pulsaras lo que pulsaras.
    $script:resultado = 'esencial'  # default si hay timeout o se cierra la ventana

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'ERDM — Elige tu experiencia'
    $form.Size = New-Object System.Drawing.Size(640, 320)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
    $form.TopMost = $true

    $titulo = New-Object System.Windows.Forms.Label
    $titulo.Text = 'Cómo quieres jugar?'
    $titulo.ForeColor = [System.Drawing.Color]::White
    $titulo.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $titulo.AutoSize = $true
    $titulo.Location = New-Object System.Drawing.Point(30, 20)
    $form.Controls.Add($titulo)

    function New-Tarjeta {
        param([string]$Nombre, [string]$Descripcion, [int]$X)

        $panel = New-Object System.Windows.Forms.Panel
        $panel.Size = New-Object System.Drawing.Size(270, 190)
        $panel.Location = New-Object System.Drawing.Point($X, 70)
        $panel.BackColor = [System.Drawing.Color]::FromArgb(36, 36, 42)
        $panel.Cursor = [System.Windows.Forms.Cursors]::Hand

        $lblNombre = New-Object System.Windows.Forms.Label
        $lblNombre.Text = $Nombre
        $lblNombre.ForeColor = [System.Drawing.Color]::White
        $lblNombre.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
        $lblNombre.AutoSize = $false
        $lblNombre.Size = New-Object System.Drawing.Size(240, 30)
        $lblNombre.Location = New-Object System.Drawing.Point(15, 15)
        $panel.Controls.Add($lblNombre)

        $lblDesc = New-Object System.Windows.Forms.Label
        $lblDesc.Text = $Descripcion
        $lblDesc.ForeColor = [System.Drawing.Color]::FromArgb(190, 190, 190)
        $lblDesc.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $lblDesc.AutoSize = $false
        $lblDesc.Size = New-Object System.Drawing.Size(240, 100)
        $lblDesc.Location = New-Object System.Drawing.Point(15, 50)
        $panel.Controls.Add($lblDesc)

        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = 'Elegir'
        $btn.Size = New-Object System.Drawing.Size(240, 32)
        $btn.Location = New-Object System.Drawing.Point(15, 145)
        $btn.BackColor = [System.Drawing.Color]::FromArgb(70, 130, 200)
        $btn.ForeColor = [System.Drawing.Color]::White
        $btn.FlatStyle = 'Flat'
        $btn.FlatAppearance.BorderSize = 0
        $panel.Controls.Add($btn)

        return @{ Panel = $panel; Boton = $btn }
    }

    $esencial = New-Tarjeta -Nombre 'Esencial' `
        -Descripcion "La experiencia de Minecraft en estado puro, con los añadidos que hacen único al servidor de El Rincón." `
        -X 30
    $graficos = New-Tarjeta -Nombre 'Gráficos Sofisticados' `
        -Descripcion 'Minecraft repensado a nivel visual: sombras, animaciones y detalle a la altura de un juego actual.' `
        -X 330

    $form.Controls.Add($esencial.Panel)
    $form.Controls.Add($graficos.Panel)

    $lblTimeout = New-Object System.Windows.Forms.Label
    $lblTimeout.ForeColor = [System.Drawing.Color]::FromArgb(130, 130, 130)
    $lblTimeout.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $lblTimeout.AutoSize = $true
    $lblTimeout.Location = New-Object System.Drawing.Point(30, 270)
    $form.Controls.Add($lblTimeout)

    $script:segundosRestantes = 60
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $actualizarLabel = {
        $lblTimeout.Text = "Si no eliges, se usará Esencial en $($script:segundosRestantes) s..."
    }
    & $actualizarLabel
    $timer.Add_Tick({
        $script:segundosRestantes--
        & $actualizarLabel
        if ($script:segundosRestantes -le 0) {
            $timer.Stop()
            $form.Close()
        }
    })
    $timer.Start()

    $esencial.Boton.Add_Click({ $script:resultado = 'esencial'; $timer.Stop(); $form.Close() })
    $graficos.Boton.Add_Click({ $script:resultado = 'graficos-sofisticados'; $timer.Stop(); $form.Close() })

    [void]$form.ShowDialog()
    return $script:resultado
}

# ------------------------------------------------------------------
#  Cambio de IP del servidor (desde 1.3.0)
#
#  servers.dat es estado PERSONAL del jugador y por eso ni packwiz ni el
#  instalador lo tocan. Pero cuando el servidor cambia de IP hay que
#  corregirlo en todas las instalaciones ya hechas. Se hace así:
#
#    - El pack distribuye erdm-servidor.json, con una lista de
#      sustituciones {"desde": "ip:puerto viejo", "hasta": "ip:puerto nuevo"}.
#    - Aquí se recorre servers.dat y SOLO las entradas cuyo "ip" coincide
#      con un "desde" se reescriben. El resto de la lista del jugador
#      (otros servidores, nombres, iconos, orden) se copia byte a byte.
#    - Es idempotente: una entrada ya corregida no coincide con ningún
#      "desde". Para un futuro cambio de IP basta con AÑADIR una línea
#      a la lista (no quitar las anteriores: hay jugadores que llevan
#      meses sin abrir el launcher).
#    - No añade entradas ni borra ninguna: si el jugador quitó el servidor
#      de su lista, no se le vuelve a poner.
#
#  servers.dat es NBT sin comprimir. Se recorre la estructura de verdad
#  (no se busca texto a ciegas) porque las cadenas llevan prefijo de
#  longitud y cambiar la IP cambia su tamaño. Si el archivo no se puede
#  interpretar, no se toca.
# ------------------------------------------------------------------
function Update-ServidoresGuardados {
    $rutaConfigServidor = Join-Path $Raiz 'erdm-servidor.json'
    $rutaServers = Join-Path $Raiz 'servers.dat'
    if (-not (Test-Path -LiteralPath $rutaConfigServidor)) { return }
    if (-not (Test-Path -LiteralPath $rutaServers)) { return }

    try {
        $config = Get-Content -LiteralPath $rutaConfigServidor -Encoding UTF8 -Raw | ConvertFrom-Json
        $mapa = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($r in @($config.reemplazos)) {
            if ($r.desde -and $r.hasta) { $mapa[[string]$r.desde] = [string]$r.hasta }
        }
        if ($mapa.Count -eq 0) { return }

        if (-not ('ErdmServersNbt' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class ErdmServersNbt
{
    static byte[] d; static int p; static MemoryStream o;
    static Dictionary<string, string> mapa;
    public static int Cambios;

    public static byte[] Reescribir(byte[] datos, Dictionary<string, string> reemplazos)
    {
        d = datos; p = 0; o = new MemoryStream(); mapa = reemplazos; Cambios = 0;
        if (d.Length < 3 || d[0] != 10) throw new InvalidDataException("no es NBT sin comprimir");
        Copiar(1);                       // tipo raiz (compound)
        int n = U16(); Copiar(2 + n);    // nombre raiz
        Carga(10, null);
        if (p < d.Length) Copiar(d.Length - p);
        return o.ToArray();
    }

    static int U16() { return (d[p] << 8) | d[p + 1]; }
    static int I32() { return (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3]; }
    static void Copiar(int n)
    {
        if (n < 0 || p + n > d.Length) throw new InvalidDataException("NBT truncado");
        o.Write(d, p, n); p += n;
    }

    static void Carga(int tipo, string nombre)
    {
        switch (tipo)
        {
            case 1: Copiar(1); break;
            case 2: Copiar(2); break;
            case 3: Copiar(4); break;
            case 4: Copiar(8); break;
            case 5: Copiar(4); break;
            case 6: Copiar(8); break;
            case 7: { int n = I32(); Copiar(4 + n); break; }
            case 8:
            {
                int n = U16();
                string valor = Encoding.UTF8.GetString(d, p + 2, n);
                string nuevo;
                if (nombre == "ip" && mapa.TryGetValue(valor, out nuevo))
                {
                    byte[] b = Encoding.UTF8.GetBytes(nuevo);
                    o.WriteByte((byte)(b.Length >> 8)); o.WriteByte((byte)(b.Length & 255));
                    o.Write(b, 0, b.Length);
                    p += 2 + n; Cambios++;
                }
                else Copiar(2 + n);
                break;
            }
            case 9:
            {
                int t = d[p]; Copiar(1);
                int n = I32(); Copiar(4);
                for (int i = 0; i < n; i++) Carga(t, null);
                break;
            }
            case 10:
            {
                while (true)
                {
                    int t = d[p]; Copiar(1);
                    if (t == 0) break;
                    int ln = U16();
                    string nom = Encoding.UTF8.GetString(d, p + 2, ln);
                    Copiar(2 + ln);
                    Carga(t, nom);
                }
                break;
            }
            case 11: { int n = I32(); Copiar(4 + 4 * n); break; }
            case 12: { int n = I32(); Copiar(4 + 8 * n); break; }
            default: throw new InvalidDataException("tipo NBT desconocido: " + tipo);
        }
    }
}
'@
        }

        $original = [System.IO.File]::ReadAllBytes($rutaServers)
        $nuevo = [ErdmServersNbt]::Reescribir($original, $mapa)
        if ([ErdmServersNbt]::Cambios -gt 0) {
            $tmp = "$rutaServers.erdm-tmp"
            [System.IO.File]::WriteAllBytes($tmp, $nuevo)
            Move-Item -LiteralPath $tmp -Destination $rutaServers -Force
            Write-Host "[ERDM] Servidor: $([ErdmServersNbt]::Cambios) entrada(s) de tu lista actualizadas a la IP nueva."
        }
    } catch {
        # Nunca debe impedir que el juego arranque, ni dejar servers.dat a medias.
        Write-Warning "[ERDM] No se pudo actualizar la IP del servidor en servers.dat ($($_.Exception.Message)); se deja como está."
    }
}

# ==================================================================
#  FASE POST
# ==================================================================
function Invoke-FasePost {

    # --- 1) Reseteo de configuración, si el jugador lo pidió ---------
    if (Test-Path $rutaResetFlag) {
        Write-Host '[ERDM] Reseteando configuración a los valores del pack...'
        Invoke-ResetConfig
        Remove-Item -LiteralPath $rutaResetFlag -Force
        Write-Host '[ERDM] Configuración reseteada.'
    }

    # --- 1b) Volver a desactivar los mods que el jugador desactivo ---
    Restore-ModsDesactivados

    # --- 2) IP nueva del servidor en servers.dat, si el pack lo indica -
    Update-ServidoresGuardados

    # --- 3) Siembra de config/ desde erdm-defaults/config/ -----------
    Invoke-SiembraConfig
}

function Invoke-ResetConfig {
    # Solo se borra lo que el propio pack gestiona (lo que hay en
    # erdm-defaults/config/), nunca configs de mods que el jugador
    # instaló por su cuenta y el pack no conoce.
    if (-not (Test-Path $rutaDefaults)) { return }

    Get-ChildItem -Path $rutaDefaults -Recurse -File | ForEach-Object {
        $rutaRelativa = $_.FullName.Substring($rutaDefaults.Length + 1)
        $rutaConfigJugador = Join-Path $rutaConfig $rutaRelativa
        if (Test-Path -LiteralPath $rutaConfigJugador) {
            Remove-Item -LiteralPath $rutaConfigJugador -Force
        }
        # Limpiar también el aviso de "hay default nuevo" si quedó de
        # una siembra anterior -- tras un reset total ya no pinta nada.
        $rutaAvisoNuevo = "$rutaConfigJugador.erdm-nuevo"
        if (Test-Path -LiteralPath $rutaAvisoNuevo) {
            Remove-Item -LiteralPath $rutaAvisoNuevo -Force
        }
    }

    if (Test-Path $rutaEstado) { Remove-Item -LiteralPath $rutaEstado -Force }
}

function Invoke-SiembraConfig {
    if (-not (Test-Path $rutaDefaults)) {
        Write-Warning 'No hay erdm-defaults/config/ -- nada que sembrar.'
        return
    }

    $estado = @{}
    if (Test-Path $rutaEstado) {
        try {
            $cargado = Get-Content -LiteralPath $rutaEstado -Encoding UTF8 -Raw | ConvertFrom-Json
            $cargado.PSObject.Properties | ForEach-Object { $estado[$_.Name] = $_.Value }
        } catch {
            Write-Warning 'erdm-estado.json no se pudo leer; se trata como si no existiera.'
        }
    }

    $nuevosCopiados = 0
    $actualizados = 0
    $respetados = 0
    $avisos = 0

    Get-ChildItem -Path $rutaDefaults -Recurse -File | ForEach-Object {
        $rutaRelativa = $_.FullName.Substring($rutaDefaults.Length + 1)
        $rutaDefaultArchivo = $_.FullName
        $rutaConfigArchivo = Join-Path $rutaConfig $rutaRelativa

        $hashDefaultNuevo = (Get-FileHash -LiteralPath $rutaDefaultArchivo -Algorithm SHA256).Hash

        if (-not (Test-Path -LiteralPath $rutaConfigArchivo)) {
            # No existe: jugador nuevo, o mod nuevo en el pack. Copiar.
            $carpetaDestino = Split-Path $rutaConfigArchivo -Parent
            if (-not (Test-Path $carpetaDestino)) { New-Item -ItemType Directory -Path $carpetaDestino -Force | Out-Null }
            Copy-Item -LiteralPath $rutaDefaultArchivo -Destination $rutaConfigArchivo -Force
            $estado[$rutaRelativa] = $hashDefaultNuevo
            $nuevosCopiados++
            return
        }

        $hashRegistrado = $estado[$rutaRelativa]
        $hashActual = (Get-FileHash -LiteralPath $rutaConfigArchivo -Algorithm SHA256).Hash

        if ($null -eq $hashRegistrado) {
            # Existe pero no hay registro previo: asumir personalizado.
            # No tocar, solo registrar el default actual para la próxima.
            $estado[$rutaRelativa] = $hashDefaultNuevo
            $respetados++
            return
        }

        if ($hashActual -eq $hashRegistrado) {
            # El jugador no lo tocó desde la última siembra: actualizar.
            if ($hashActual -ne $hashDefaultNuevo) {
                Copy-Item -LiteralPath $rutaDefaultArchivo -Destination $rutaConfigArchivo -Force
                $estado[$rutaRelativa] = $hashDefaultNuevo
                $actualizados++
            }
            return
        }

        # El jugador lo personalizó: no tocar. Si el default cambió
        # desde entonces, avisar y dejar una copia de referencia al lado.
        if ($hashDefaultNuevo -ne $hashRegistrado) {
            $rutaNuevo = "$rutaConfigArchivo.erdm-nuevo"
            Copy-Item -LiteralPath $rutaDefaultArchivo -Destination $rutaNuevo -Force
            Write-Host "[ERDM] Nuevo default disponible para '$rutaRelativa' (el tuyo está personalizado, no se toca): $(Split-Path $rutaNuevo -Leaf)"
            $estado[$rutaRelativa] = $hashDefaultNuevo
            $avisos++
        }
        $respetados++
    }

    $json = ($estado | ConvertTo-Json -Depth 5)
    Write-TextoSinBom -Ruta $rutaEstado -Texto $json

    Write-Host "[ERDM] Config: $nuevosCopiados nuevos, $actualizados actualizados, $respetados respetados, $avisos avisos de default nuevo."
}

# ==================================================================
switch ($Fase) {
    'Pre'  { Invoke-FasePre }
    'Post' { Invoke-FasePost }
}
