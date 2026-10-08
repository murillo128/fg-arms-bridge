# Arms Bridge · O.R.T.I.C.E.

Extensión experimental para **Fantasy Grounds, sistema 5E y D&D 2024**, acompañada de *El nuevo Arms Law*, un manual ilustrado con tablas por arma. La referencia de diseño es **Arms Law de Rolemaster Classic, de ICE**: relacionar la calidad del ataque con el daño y distinguir la protección material de la defensa adicional.

**Estado: 0.3.1 alpha.** El motor y sus contratos de integración tienen pruebas automatizadas; la comprobación dentro de Fantasy Grounds sigue pendiente. Las curvas incluidas son originales y experimentales. Su calibración no está terminada.

## Qué incluye

- D20 abiertos: un 20 inicial permite sumar otro d20; cada nuevo 20 continúa la cadena. El daño físico adicional sigue creciendo por encima de la última fila.
- Ocho familias de armas, siete perfiles de protección y un catálogo de cuarenta armas, con categoría simple/marcial y uso a una o dos manos registrados por separado.
- Conversión de los dados físicos base según su distribución: `1d12` y `2d6` conservan distribuciones distintas aunque compartan familia.
- Componentes adicionales de ácido, fuego, necrótico y otros tipos separados. Fantasy Grounds conserva la aplicación nativa de resistencias, inmunidades y vulnerabilidades por tipo.
- Críticos nativos de D&D, sin tablas adicionales de lesiones o críticos de Rolemaster.
- Manual de 52 páginas, tablas por arma, introducción, ejemplos y material gráfico con estética de los años ochenta.

## Descargar e instalar

Las versiones se distribuyen en [Releases](https://github.com/murillo128/fg-arms-bridge/releases). Cada publicación reúne una `.ext`, el PDF y sus sumas SHA-256. Los mismos entregables se versionan como dos artefactos OCI en GitHub Packages:

| Entregable | Package |
|---|---|
| Extensión | `ghcr.io/murillo128/fg-arms-bridge-extension` |
| Manual | `ghcr.io/murillo128/fg-arms-bridge-manual` |

Copia la `.ext` en la carpeta `extensions` del directorio de datos de Fantasy Grounds y actívala en una campaña de prueba 5E. Empieza con `/arms status` y el modo `compare`, que muestra el cálculo alternativo. Resuelve cada ataque y su daño de forma consecutiva, desde el mismo cliente y con un único objetivo.

La [guía de uso](docs/USAGE.md) explica los comandos, las armaduras, los componentes de daño y los límites de esta alpha. El [ensayo en Fantasy Grounds](docs/SMOKE_TEST.md) describe las comprobaciones pendientes dentro del programa.

## Fuentes y construcción

| Ruta | Contenido |
|---|---|
| `extension/` | Lua, XML y recursos del paquete instalable |
| `tests/`, `tools/` | Pruebas, análisis y empaquetado de la extensión |
| `manual/` | Contenido, tablas, ilustraciones, tipografías y generadores del PDF |
| `docs/` | Uso, integración, equilibrio y procedimientos de construcción/publicación |
| `.github/workflows/` | Validación, publicación e infraestructura de desarrollo heredada |

El motor de la extensión no requiere bibliotecas externas. Sus herramientas de desarrollo utilizan Python y Lua. El constructor del manual añade dependencias Python fijadas y tipografías incluidas con sus avisos de licencia.

```bash
python3 tools/test.py --require-lua
python3 tools/build.py
```

Consulta [manual/README.md](manual/README.md) para reconstruir las tablas y el PDF. Los productos generados se distribuyen en Releases y Packages; las imágenes finales y los scripts de generación se conservan en Git.

## Reglas y límites

La defensa adicional se separa de la protección material. Las familias y perfiles son aproximaciones de campaña, no equivalencias oficiales entre D&D y los tipos de armadura de Rolemaster. Las protecciones naturales y algunas familias reutilizan curvas iniciales que requieren calibración. La [evaluación numérica](docs/BALANCE.md) documenta estas limitaciones.

Los críticos mantienen los dados nativos de D&D y añaden el suplemento físico una sola vez. La extensión no escribe directamente los puntos de golpe. Si no puede identificar con seguridad el componente físico o el contexto de un ataque, conserva la resolución nativa y emite un aviso.

El catálogo incluye dos propuestas de campaña, shuriken y trabuco, que no se presentan como armas oficiales de D&D 2024. La cerbatana de daño fijo conserva el daño nativo en esta alpha.

## Licencia y procedencia

El código, la documentación y los datos originales de demostración de la extensión se distribuyen bajo [MIT](LICENSE). Las tipografías y los materiales gráficos conservan sus avisos y registros de procedencia. No se incluyen las tablas comerciales de Arms Law ni el código de los sistemas comerciales de Fantasy Grounds. Las marcas citadas identifican las referencias y plataformas correspondientes; este proyecto es independiente.
