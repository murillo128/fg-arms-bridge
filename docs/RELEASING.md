# Construcción y publicación de versiones

La versión de distribución se lee de `VERSION`. La primera es `0.3.1-alpha`,
asociada a la prerelease `v0.3.1-alpha`. El sufijo identifica el estado editorial;
la base `0.3.1` debe coincidir con el motor, el manifiesto de la extensión, el
catálogo y los datos del manual. No cambia la versión del esquema.

## Construir localmente

Se recomienda Python 3.12 y Lua 5.4. Los archivos tipográficos y sus avisos se
incluyen en el proyecto; la construcción utiliza los PNG definitivos y no genera
ilustraciones nuevas.

```sh
python3 -m pip install -r manual/requirements.txt
python3 tools/build_release.py
```

El constructor ejecuta la suite de extensión con Lua obligatorio una vez,
incluidas las pruebas de publicación. Comprueba las versiones, compara la
exportación del motor con las tablas versionadas, ejecuta el verificador numérico
independiente y construye el PDF y los archivos de distribución. La salida es:

```text
dist/release/ArmsBridge-0.3.1-alpha.ext
dist/release/El-nuevo-Arms-Law-0.3.1-alpha.pdf
dist/release/fg-arms-bridge-0.3.1-alpha-source.zip
dist/release/SHA256SUMS
```

`SHA256SUMS` contiene las sumas de los tres archivos versionados. El directorio
de salida debe contener exactamente estos cuatro archivos. Las salidas,
credenciales, renders y cachés no se añaden al historial Git.

El workflow **Arms Bridge product checks** ejecuta este mismo comando en un
runner alojado `ubuntu-24.04`, con Python 3.12, Lua 5.4 y las dependencias fijadas
en `manual/requirements.txt`. Se aplica a los PR, a los pushes de `main` y a su
ejecución manual. Los workflows heredados de Skillforge conservan sus propios
eventos, condiciones y responsabilidades.

## Qué se publica

La Release del repositorio público ofrece descargas directas del `.ext`, el PDF,
el ZIP de fuentes y `SHA256SUMS`. Para la versión inicial:

- [ArmsBridge-0.3.1-alpha.ext](https://github.com/murillo128/fg-arms-bridge/releases/download/v0.3.1-alpha/ArmsBridge-0.3.1-alpha.ext)
- [El-nuevo-Arms-Law-0.3.1-alpha.pdf](https://github.com/murillo128/fg-arms-bridge/releases/download/v0.3.1-alpha/El-nuevo-Arms-Law-0.3.1-alpha.pdf)
- [fg-arms-bridge-0.3.1-alpha-source.zip](https://github.com/murillo128/fg-arms-bridge/releases/download/v0.3.1-alpha/fg-arms-bridge-0.3.1-alpha-source.zip)
- [SHA256SUMS](https://github.com/murillo128/fg-arms-bridge/releases/download/v0.3.1-alpha/SHA256SUMS)

Estos enlaces estarán disponibles después de la primera ejecución correcta del
workflow **Publish Arms Bridge release**. La publicación no convierte las pruebas
con mocks en una certificación de Fantasy Grounds: la prueba real del anfitrión
sigue pendiente y las curvas siguen siendo experimentales.

El mismo workflow distribuye dos artefactos OCI mediante ORAS:

| Package y etiqueta | Contenido exacto |
| --- | --- |
| `ghcr.io/murillo128/fg-arms-bridge-extension:0.3.1-alpha` | `ArmsBridge-0.3.1-alpha.ext`, `application/zip` |
| `ghcr.io/murillo128/fg-arms-bridge-manual:0.3.1-alpha` | `El-nuevo-Arms-Law-0.3.1-alpha.pdf`, `application/pdf` |

Cada paquete contiene un archivo, con las anotaciones OCI `source`, `version`,
`revision` y `created`. `source` identifica este repositorio; `revision` es el
commit completo; `created` usa la fecha del commit para mantener una identidad
estable en los reintentos. El uso de `GITHUB_TOKEN` vincula los paquetes con el
repositorio que ejecuta la publicación.

GitHub crea inicialmente los paquetes GHCR con visibilidad privada. Esa
visibilidad es independiente de la del repositorio. Esta primera publicación
admite ese estado; las descargas directas de la Release son públicas. El dueño
puede cambiar posteriormente cada paquete a **Public** desde **Package settings
→ Change visibility**. El workflow no utiliza una API no documentada para
modificar esa opción. Una vez públicos, los archivos se pueden obtener sin
autenticación mediante:

```sh
oras pull ghcr.io/murillo128/fg-arms-bridge-extension:0.3.1-alpha
oras pull ghcr.io/murillo128/fg-arms-bridge-manual:0.3.1-alpha
```

## Inicio y nuevas versiones

La integración inicial en `main` añade `VERSION` y el workflow de publicación;
ese push inicia la primera entrega. Los pushes posteriores de `main` que cambien
`VERSION` o los archivos de publicación también lo inician. Los pushes de
etiquetas `v*` y `workflow_dispatch` permiten publicar o reintentar explícitamente.
Los filtros de rutas no se aplican a los pushes de etiquetas.

Antes de construir, el paso `--preflight` comprueba el repositorio, el acceso,
la versión, el commit y la publicación existente. Un commit posterior de `main`
con una versión ya publicada desde uno de sus antecesores omite la publicación
sin sustituir archivos. La Release anterior debe contener el conjunto completo
de activos cargados. Una etiqueta explícita debe coincidir con `v` seguido de `VERSION`
y apuntar al commit que se ha extraído; cualquier discrepancia falla.

Para una nueva entrega, actualiza de forma coherente `VERSION` y las versiones
del producto, regenera los datos que corresponda y somete la construcción al
proceso de PR habitual. Al integrar el cambio de versión en `main`, se publica
la nueva etiqueta. Las versiones con sufijo, como `-alpha`, se marcan como
prereleases y no se establecen como `Latest`.

Packages y Release se publican en la misma ejecución. El flujo no depende de que
la etiqueta o la Release creada por `GITHUB_TOKEN` dispare un segundo workflow.
El token nativo utiliza solamente `contents: write` y `packages: write`; no hay
PAT externo. GitHub puede rechazar la creación de una Release sobre un commit
cuyos workflows difieran de los de la rama predeterminada si exige permisos de
Workflows que `GITHUB_TOKEN` no puede recibir. La ruta normal publica después de
integrar en `main`; un rechazo HTTP se conserva como error, nunca como ausencia.

## Integridad, reintentos y conflictos

El publicador comprueba primero las sumas locales y cualquier activo remoto
existente. Reserva la procedencia mediante una etiqueta Git y crea una Release
en borrador con un marcador que identifica versión y commit. Comprueba o carga
ambos paquetes, descarga cada uno por el digest inmutable de su manifiesto y
verifica los bytes. También vuelve a comprobar que la etiqueta OCI no cambió
durante esa descarga.

Los activos existentes de la Release se descargan y se comparan con las sumas
locales; las sumas que proporcione la API se comprueban adicionalmente. Solo se
cargan nombres que falten. Antes de publicar el borrador se comprueban otra vez
todos los activos y la procedencia de la etiqueta Git. Un único grupo de
concurrencia serializa las publicaciones del repositorio.

Si se interrumpe una carga, vuelve a ejecutar el workflow original, sobre el
mismo commit y con las mismas dependencias. Un paquete terminado y un activo
aceptado cuya respuesta se perdió se verifican y se conservan; se completan los
elementos ausentes. Los borradores se buscan con paginación para recuperar una
entrega interrumpida. Un borrador ajeno, sin el marcador de procedencia esperado,
no se modifica.

Un archivo diferente, una etiqueta que apunte a otro commit, un activo con estado
incompleto o un conjunto de activos inesperado detiene la publicación. No se
borran activos, no se mueven etiquetas y no se emplea `--clobber`. Un error de
autenticación, autorización, límite de servicio o transporte tampoco se interpreta
como que falta el recurso. En GHCR, solo un `404` autenticado con código OCI
`MANIFEST_UNKNOWN` o `NAME_UNKNOWN` establece ausencia.

Si un servicio deja un activo vacío con estado de carga incompleto, el workflow
lo señala y no lo elimina automáticamente. La recuperación debe preservar la
versión original; si cambian los bytes o la procedencia, crea una nueva versión.
Una publicación antigua incompleta se reintenta desde su ejecución original,
no desde un commit posterior que reutilice el mismo número. Las etiquetas de
estos paquetes deben permanecer bajo el publicador; no se deben retaggear con
otras herramientas mientras se ejecuta.

El token se entrega a ORAS por entrada estándar. Su configuración de registro
se mantiene en un directorio temporal, con permisos restrictivos, que se elimina
al terminar. Las redirecciones de las descargas a otro origen eliminan las
cabeceras de autenticación. Las credenciales no se guardan en Git ni en artefactos.

## Pruebas y referencias

La cobertura offline está en `tests/test_publish_release.py` y usa archivos
reales pequeños, sumas SHA-256 y dobles de los transportes HTTP/ORAS. Prueba la
primera entrega, repetición exacta, respuesta de upload perdida, recuperación de
borradores paginados, conflictos de bytes y procedencia, carreras de etiquetas,
errores HTTP/red y verificación de descargas. También comprueba el contexto de
Actions y que un cambio de origen no arrastre credenciales. Se ejecuta con:

```sh
python3 tests/test_publish_release.py
```

Estas pruebas verifican la lógica de publicación. La compatibilidad del binario
ORAS instalado y los permisos/servicios reales se verifican en el workflow
posterior a la integración, mediante las cargas y descargas efectivas.

Los workflows fijan `actions/checkout` v7.0.1, `actions/setup-python` v7.0.0 y
`oras-project/setup-oras` v2.0.2 por sus SHA completos, e instalan ORAS CLI 1.3.4.
El cliente REST declara la versión de API `2026-03-10`. Referencias primarias:

- [GitHub Container registry y autenticación con GITHUB_TOKEN](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry).
- [Visibilidad y herencia de permisos de Packages](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility).
- [REST de Releases y borradores](https://docs.github.com/en/rest/releases/releases).
- [Versiones de la API REST](https://docs.github.com/en/rest/about-the-rest-api/api-versions).
- [Eventos generados por GITHUB_TOKEN](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow).
- [Filtros de rutas y etiquetas en workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).
- [ORAS: GHCR compatible](https://oras.land/docs/compatible_oci_registries/#github-packages-container-registry-ghcr), [push](https://oras.land/docs/commands/oras_push/) y [autenticación Registry V2](https://distribution.github.io/distribution/spec/auth/token/).
- [checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1), [setup-python v7.0.0](https://github.com/actions/setup-python/releases/tag/v7.0.0), [setup-oras v2.0.2](https://github.com/oras-project/setup-oras/releases/tag/v2.0.2) y [ORAS 1.3.4](https://github.com/oras-project/oras/releases/tag/v1.3.4).
