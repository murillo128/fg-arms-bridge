# Construcción, validación y versiones

El repositorio contiene la extensión en `extension/` y el manual ilustrado en `manual/`. Desde una copia de trabajo preparada, una orden valida el proyecto y construye los cuatro archivos de distribución:

```sh
python3 tools/build_release.py
```

La instalación y el uso de la extensión se describen en [USAGE.md](USAGE.md). Este documento explica cómo producir y comprobar sus archivos.

## Preparar el entorno

Utiliza **Python 3.12 y Lua 5.4**. Para revisar páginas renderizadas necesitas además Poppler, con `pdftoppm` disponible en el PATH. Desde la raíz del repositorio, crea un entorno virtual e instala las versiones fijadas:

```sh
python3.12 -m venv .venv
. .venv/bin/activate
python3 -m pip install -r manual/requirements.txt
```

La activación anterior corresponde a una shell POSIX; en Windows puede utilizarse el intérprete de `.venv\Scripts\python.exe` para ejecutar las mismas órdenes Python. Las dependencias fijadas están en [manual/requirements.txt](../manual/requirements.txt). La composición utiliza las tipografías incluidas en [manual/fonts/](../manual/fonts/), junto con sus avisos y hashes. No depende de elegir una fuente alternativa instalada en cada equipo.

Los originales PNG están en [manual/assets/](../manual/assets/). Son las entradas de reproducción del arte y deben conservarse byte por byte. [PROVENANCE.md](../manual/PROVENANCE.md) explica sus hashes, las referencias y los prompts conservados.

## Construir una distribución

El archivo [VERSION](../VERSION) contiene la versión completa de publicación, inicialmente `0.3.1-alpha`. Su parte base, `0.3.1`, debe coincidir con la extensión, el motor, el catálogo y los datos del manual. La designación editorial `0.3.1 alpha` se conserva en el documento. El número de versión del producto no cambia los campos `schema_version` de sus datos.

```sh
python3 tools/build_release.py
```

El resultado se escribe en `dist/release/`:

| Archivo inicial | Contenido |
|---|---|
| `ArmsBridge-0.3.1-alpha.ext` | Extensión para Fantasy Grounds |
| `El-nuevo-Arms-Law-0.3.1-alpha.pdf` | Manual A4 de 52 páginas y cuarenta tablas de armas |
| `fg-arms-bridge-0.3.1-alpha-source.zip` | Fuentes, datos, arte final, tipografías y herramientas de construcción |
| `SHA256SUMS` | Sumas SHA-256 de los archivos distribuidos |

Puede elegirse otro directorio sin omitir las validaciones:

```sh
python3 tools/build_release.py --output dist/review
```

El comando ejecuta la suite de la extensión con `--require-lua`, comprueba la coherencia de versiones, verifica las tablas y los materiales e integra la construcción del PDF. Los artefactos se generan localmente; esta orden no publica en GitHub ni en un registro de paquetes.

Si el directorio de salida ya contiene archivos, el constructor exige que sean idénticos antes de completar una distribución parcial. No sobrescribe contenidos diferentes. Para comparar revisiones locales todavía en desarrollo, elige directorios de salida distintos con `--output`.

Para comprobar los archivos de una distribución descargada, ejecuta desde su directorio:

```sh
sha256sum -c SHA256SUMS
```

## Trabajo sobre el manual

Estas órdenes se ejecutan desde la raíz del repositorio. Si se cambia el motor o el exportador, regenera primero los datos y comprueba sus valores:

```sh
lua5.4 manual/tools/export_tables.lua
python3 manual/tools/verify_tables.py
```

El exportador también acepta rutas explícitas al motor y al archivo de salida. Por ejemplo, para inspeccionar una exportación sin sustituir los datos guardados:

```sh
mkdir -p manual/tmp
lua5.4 manual/tools/export_tables.lua extension/scripts/arms_engine.lua manual/tmp/tables-review.json
python3 manual/tools/verify_tables.py manual/tmp/tables-review.json
```

El verificador utiliza aritmética racional y distribuciones exactas de dados. El constructor del PDF consume los JSON comprobados; no recalcula las curvas durante la maquetación.

Para construir e inspeccionar el manual:

```sh
python3 manual/tools/build_book.py --render-qa
```

El PDF de trabajo queda en `manual/output/pdf/El-nuevo-Arms-Law.pdf`. La auditoría y las vistas de revisión quedan en `manual/tmp/pdfs/`. La auditoría comprueba 52 páginas, cuarenta páginas de armas, extracción de títulos y ajuste de tablas y párrafos. La revisión visual debe confirmar la portada, una tabla representativa y las ilustraciones afectadas por cada cambio. Los ejemplos de renderizado de páginas concretas están en [manual/README.md](../manual/README.md).

## Reproducción y contenido del archivo fuente

Las versiones de dependencias, las tipografías y los PNG se fijan para conservar la composición. Con el mismo entorno de construcción, los archivos PDF y ZIP deben ser idénticos aunque cambie el nombre o la ruta de la copia de trabajo. Las comprobaciones de empaquetado cubren esa condición; no se presupone igualdad entre entornos con versiones distintas.

El archivo fuente conserva el código y los materiales necesarios: datos del manual, PNG finales, prompts y procedencia, tipografías con sus avisos y scripts. Excluye renderizados, `manual/output/`, `manual/tmp/`, cachés, archivos de distribución anteriores y descargas originales de retratos o páginas de campaña. Los nombres internos del ZIP no dependen del nombre de la carpeta desde la que se construye.

La suite de la extensión también puede ejecutarse por separado:

```sh
python3 tools/test.py --require-lua
```

Las pruebas automáticas de Lua y los dobles del entorno de Fantasy Grounds no sustituyen la prueba real descrita en [SMOKE_TEST.md](SMOKE_TEST.md). Esa prueba sigue pendiente para esta alpha; las curvas continúan siendo experimentales.

## Publicación y verificación

Los workflows alojados de [GitHub Actions](../.github/workflows/) validan los cambios y construyen los artefactos. La publicación de una versión utiliza en la misma ejecución los archivos de extensión y manual para sus paquetes OCI y para los adjuntos de la Release. Se registran versión, repositorio fuente y revisión del código.

La primera versión corresponde a la prerelease `v0.3.1-alpha` y a estos dos destinos:

- `ghcr.io/murillo128/fg-arms-bridge-extension:0.3.1-alpha`.
- `ghcr.io/murillo128/fg-arms-bridge-manual:0.3.1-alpha`.

La Release proporciona descargas directas públicas de `.ext`, PDF, fuentes y `SHA256SUMS`. Los paquetes de GHCR pueden conservar su visibilidad privada inicial; su publicación no implica que permitan descargas anónimas. La verificación de publicación recupera los contenidos desde el registro y desde la Release y comprueba sus hashes.

Las versiones publicadas son inmutables. Una repetición puede verificar una publicación idéntica o completar una publicación parcial compatible; no reemplaza archivos o etiquetas que difieren. Un commit posterior en `main` con una versión ya publicada puede omitir una nueva publicación; una etiqueta explícita que no coincide debe fallar. Para distribuir cambios de contenido se requiere una nueva versión coherente en código, datos y `VERSION`.
