# Lógica del launcher ERDM (auto-actualizable)

Ramas de este repo: `logica` (estable, la siguen todos los jugadores) y
`logica-pruebas` (solo instalaciones con `erdm-canal.txt` = `pruebas`).
No contienen el modpack: ese está en `main` y `sofisticado`.

El lanzador fijo (`erdm-launcher.ps1`, dentro del instalador) baja `logica.json`,
elige la versión más alta compatible, comprueba su sha256 y ejecuta
`v<N>/erdm-logica.ps1`. Publicar con `publicar-logica.ps1` (ver su cabecera).
