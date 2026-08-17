# ERDM-Official

Modpack del SMP privado **El Rincón de Minecraft**, distribuido con
[packwiz](https://packwiz.infra.link/). Se auto-actualiza en cada arranque.

| | |
|---|---|
| Minecraft | `26.2` |
| Cargador | Fabric `0.19.3` |
| Mods | 39 |
| Resourcepacks | 17 |
| Shaders | 2 |

---

## Cómo funciona

La instancia de Prism tiene un **pre-launch command** que ejecuta
`packwiz-sync.bat` antes de abrir el juego:

```
PreLaunchCommand=cmd /c packwiz-sync.bat
```

### Por qué un .bat y no el comando directo

La forma que documenta packwiz es
`"$INST_JAVA" -jar packwiz-installer-bootstrap.jar <url>`, y **no se puede
escribir a mano en `instance.cfg`**. Prism guarda ese archivo con `QSettings`
en formato INI (`INIFile::saveFile`), donde las comillas son delimitadores: al
guardar convierte `PreLaunchCommand="$INST_JAVA" -jar ...` en
`PreLaunchCommand=$INST_JAVA-jar ...` —se come las comillas y colapsa el
espacio contiguo— y el lanzamiento falla con
`The system cannot find the file specified`. Escribirlo desde la interfaz de
Prism sí funciona, porque entonces QSettings aplica su propio escapado.

`cmd /c packwiz-sync.bat` no lleva comillas, backslashes, `=`, `,` ni `;`, así
que QSettings lo conserva tal cual. El entrecomillado de rutas con espacios se
resuelve dentro del `.bat`, donde las reglas de cmd.exe son predecibles.

### El `.bat` no se fía de `%INST_JAVA%`

Hay una segunda trampa, y solo se manifiesta en el **primer arranque tras
instalar**. Prism captura el entorno del pre-launch en el *constructor* del paso
(`PreLaunchCommand.cpp` → `createEnvironment()`), o sea al construir la lista de
pasos — **antes de que `AutoInstallJava` se ejecute** y resuelva el Java. En una
instalación nueva `JavaPath` aún está vacío, y `getVariables()` hace:

```cpp
QDir::toNativeSeparators(QDir(settings()->get("JavaPath").toString()).absolutePath())
```

`QDir("").absolutePath()` devuelve el **directorio de trabajo**, así que
`%INST_JAVA%` llega valiendo la carpeta del launcher en lugar de un ejecutable,
y cmd responde `9009` (*no se reconoce como comando*). A partir del segundo
arranque ya sería correcto — pero el primero es el de todos los jugadores nuevos.

Ojo con la comprobación: `if exist` **también es cierto para carpetas**, así que
verificar la existencia no basta; hay que exigir que sea un fichero `.exe`. Por
eso el `.bat` valida `%INST_JAVA%` y, si no sirve, busca el runtime por su
cuenta en `<launcher>\java\*\bin\java.exe` partiendo de `%~dp0`.

`$INST_JAVA` **en la cadena del comando** sí se resuelve al ejecutar y sería
correcto; es la *variable de entorno* la que está congelada. Ambas se llaman
igual y valen cosas distintas.

El `.bat` además usa `java.exe` en vez de `javaw.exe` (que no escribe en la
consola) para que los errores de packwiz aparezcan en el registro de Prism, y
pasa `--bootstrap-no-update`: sin ese flag el bootstrap consulta
`api.github.com` en **cada arranque**, y si GitHub no responde el pre-launch
devuelve error y Prism aborta el lanzamiento. Para actualizar el instalador
algún día, borra `packwiz-installer.jar` y quita el flag una vez.

`packwiz-sync.bat` viaja en el instalador y está en `.packwizignore`: si se
distribuyera por el pack, packwiz podría reescribirlo mientras cmd.exe lo está
ejecutando.

En cada arranque, el instalador compara `index.toml` con lo que el jugador
tiene y descarga solo lo que cambió. Los mods y packs se bajan de la CDN de
Modrinth, no de este repositorio — aquí solo viven los metadatos (`.pw.toml`),
la configuración y los emotes. Por eso el repo pesa ~2,6 MB en vez de 115 MB.

**Los ajustes locales del jugador no se pisan.** El instalador guarda un
manifiesto (`packwiz.json`) y solo sobrescribe un archivo cuando su hash cambia
*en el repositorio*. Si un jugador edita su `config/sodium-options.json`, se
mantiene hasta que ese archivo concreto se modifique aquí.

---

## Publicar una actualización

1. Abre Prism, cambia lo que quieras en la instancia (mods, config, packs).
2. **Cierra Prism.**
3. Ejecuta:

```powershell
.\actualizar-pack.ps1 -Mensaje "Añadido Create"
```

El script sincroniza los metadatos, regenera el índice y hace `git push`.
Para ver qué cambiaría sin subir nada: `.\actualizar-pack.ps1 -SoloLocal`.

`raw.githubusercontent.com` cachea unos minutos, así que la actualización
puede tardar un poco en llegar a todos.

---

## Dos trampas que hay que conocer

### 1. `mods/.index/` no se indexa

Prism escribe sus propios `.pw.toml` en `mods/.index/`, en formato packwiz.
Es tentador indexarlos desde ahí, pero **rompe el pack**: packwiz-installer
resuelve el destino del `.jar` como hermano del metafile, así que los mods se
instalarían en `mods/.index/` y el juego arrancaría sin ninguno.

La copia autoritativa vive en `mods/`. `mods/.index/` está en `.packwizignore`
y en `.gitignore`, y `actualizar-pack.ps1` mantiene las dos sincronizadas.

### 2. Sacar algo del índice lo BORRA de las instancias

packwiz-installer lleva un manifiesto (`packwiz.json`) de lo que instaló. Si un
archivo desaparece de `index.toml`, en el siguiente arranque lo **elimina** del
disco. Es lo correcto para un mod retirado, pero recuerda que esta carpeta es a
la vez el repo y una instancia jugable: al excluir `README.md` y
`actualizar-pack.ps1` del índice, el instalador los borró de aquí. Se
recuperaron con `git restore`. Si sacas algo del índice y además no está en
git, lo pierdes.

### 3. Todo se ignora por defecto

Esta carpeta es la carpeta `minecraft` de la instancia: contiene ~1 GB de datos
locales (mundos, cachés, los ~280 MB de binarios que DreamDisplays se descarga
solo). Tanto `.gitignore` como `.packwizignore` funcionan como lista blanca
o denylist explícito. **Si añades un tipo de contenido nuevo, revisa ambos.**

---

## Estructura

```
pack.toml            # metadatos del pack (versión de MC y Fabric)
index.toml           # índice + hashes de los 166 archivos
mods/*.pw.toml       # 39 metadatos -> CDN de Modrinth
resourcepacks/       # 17 metadatos
shaderpacks/         # 2 metadatos + ajustes .zip.txt
config/              # 84 archivos de configuración
emotes/              # 21 emotes de Emotecraft
actualizar-pack.ps1  # script de publicación
```
