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
`packwiz-installer-bootstrap.jar` antes de abrir el juego:

```
"$INST_JAVA" -jar packwiz-installer-bootstrap.jar https://raw.githubusercontent.com/samuelvelero/erdm-launcherpack/main/pack.toml
```

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

### 2. Todo se ignora por defecto

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
