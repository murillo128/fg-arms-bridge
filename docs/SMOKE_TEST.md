# Comprobación dentro de Fantasy Grounds

Esta comprobación de la versión 0.3.1 requiere una instalación real. **Pendiente de realizar**: no debe confundirse con las pruebas automatizadas del proyecto. Usa primero una campaña de prueba 5E/2024 y únicamente Arms Bridge para separar problemas del paquete de conflictos con otras extensiones.

## Preparación

Crea un atacante con un arma `1d8+3` cortante y una diana con CA 15. Añade ambos al combat tracker. Asigna `/arms armor "Diana" leather 12`, comprueba la acción del arma con `/arms weapon "Longsword" bladed` y ejecuta `/arms status`. Abre `/arms` y verifica texto, botones, importación y cierre del panel. El diagnóstico debe indicar capacidades disponibles, no errores Lua.

## Ataque y daño

1. En modo `compare`, realiza un ataque y daño. La comparación debe aparecer sin cambiar el impacto, el daño aplicado ni la CA almacenada.
2. Cambia a `on`. Realiza un ataque con un solo objetivo; espera a terminar todas sus continuaciones y tira el daño desde el mismo cliente. El chat debe mostrar la calidad aplicada o el suplemento; los modificadores previos se conservan y el suplemento se añade una sola vez.
3. Repite con ventaja y desventaja. La resolución debe usar el dado que seleccionó Fantasy Grounds; no se sustituye ventaja por un modificador fijo.
4. Comprueba un 1 natural y un 20 natural mediante el mecanismo de dados manuales del programa. El 1 falla; el 20 impacta, conserva el crítico y solicita otro d20. Completa las cadenas `20+10`, `20+20+10` y `20+1`: la suma debe ser 30, 50 y 21. Solo los 20 abren, y el 1 de continuación no produce una pifia. Fija los dados de daño crítico bajos: no se maximizan ni se duplican de nuevo por cada 20. Repite con un crítico reconocido en 19 por un rasgo: debe ser crítico sin abrir. Ningún contexto debe convertir un daño posterior.
5. Repite con un arma `2d6`. La calidad gobierna la suma de la base y puede producir dados distintos, no dos dados forzados al mismo valor.
6. Añade una cláusula de daño elemental y una resistencia de la diana. Solo los dados físicos base deben convertirse; el procesamiento nativo debe aplicar la resistencia al componente correcto. Sigue las comprobaciones por tipos de la siguiente sección.

Para comprobar la corrección numérica de 0.3.1 con las tablas por defecto, ejecuta `/arms preview bladed unarmored 11 5 0 1d12+3`. Debe obtener `R = 16`, índice 80 y calidad 0,50: la base del d12 es 6, no 7, y el total con el modificador es 9.

Para comprobar cifras concretas del suplemento, cambia la diana a placas con `/arms armor "Diana" plate 18` y CA nativa 18, y usa un atacante con bonificación de ataque +5 y `Longsword` asociado a `bladed`. Con `1d8+3`, `20+10` debe añadir 4 al crítico nativo y `20+20+10` debe añadir 13. Con `2d6+3`, los mismos resultados deben añadir 6 y 20. El modificador +3 se suma una vez. Comprueba que el suplemento hereda el tipo cortante del componente base y que una resistencia a cortante lo reduce junto con ese componente, mientras una cláusula de fuego mantiene su daño propio.

Usa ventaja con un 20 y otro dado menor: se abre una sola cadena. Con desventaja, un 20 descartado no debe abrir; dos 20 abren una cadena. Una vez abierta, ninguna continuación debe recibir ventaja, penalizadores de ataque, dados de Bless o modificadores de la bandeja. Comprueba la visibilidad de ataques secretos y de torre con el host y un jugador.

Solicita daño mientras la cadena está abierta. En esta alpha se debe conservar el daño nativo con un aviso y descartar el contexto: no existe espera automática validada para esa solicitud precoz. Completar después la continuación no puede sumar daño tardío ni afectar otro lanzamiento. Repite una continuación arrastrándola desde el chat: su token no puede volver a sumarse. Cancela una cadena con `/arms clear` y comprueba que las respuestas posteriores quedan invalidadas.

## Componentes, resistencias y críticos

Configura el daño como dos líneas: `1d8+3` cortante y `1d4` de fuego. En un impacto ordinario verifica que solo cambia el d8 físico, que el modificador no se duplica y que la línea elemental conserva su resultado. Repite poniendo el fuego primero y el físico después; repite con dos d8 de tipos diferentes para que el tamaño de dado no pueda ocultar un intercambio. Haz la comprobación con ácido y necrótico, y después con frío, fuerza, relámpago, veneno, psíquico, radiante y trueno. Revisa tanto los dados y el texto como los puntos de golpe aplicados: el total visible por sí solo no demuestra que la codificación por tipos sea correcta.

Obtén mediante dados manuales o una tabla de prueba una salida de **9 cortantes y 3 de fuego antes de defensas por tipo**. Usa un único impacto, sin otros modificadores, y compara:

| Propiedades de la diana | Cortante aplicado | Fuego aplicado | Total |
|---|---:|---:|---:|
| Ninguna | 9 | 3 | 12 |
| Resistencia a fuego | 9 | 1 | 10 |
| Resistencia a cortante | 4 | 3 | 7 |
| Inmunidad a fuego | 9 | 0 | 9 |
| Inmunidad a cortante | 0 | 3 | 3 |
| Vulnerabilidad a fuego | 9 | 6 | 15 |
| Resistencia y vulnerabilidad a fuego | 9 | 2 | 11 |

Estas cifras siguen las reglas generales de [D&D 2024](https://www.dndbeyond.com/sources/dnd/br-2024/playing-the-game). Las propiedades de resistencia no deben introducir una segunda reducción desde Arms Bridge. Prueba también dos componentes adicionales del mismo tipo y las condiciones de resistencia que use tu campaña, conservando las etiquetas nativas de magia y material. No asumas que el grupo `blunted` convierte daño perforante en contundente.

En un crítico del arma `1d8+3` cortante más `1d4` necrótico, comprueba que el sistema prepara `2d8+3` cortantes y `2d4` necróticos, con el suplemento abierto añadido únicamente al componente cortante. Fija resultados bajos y confirma que ningún dado se maximiza por calidad. La resistencia física debe reducir también el suplemento; la necrótica debe afectar solo al componente necrótico. Repite con el componente necrótico antes del físico. No actives otra vez el crítico al obtener un 20 de continuación.

Prueba un componente adicional físico con una marca explícita `critical` o `precision` y confirma que no se selecciona como base. Si el sistema no añade una marca diferenciadora a un extra físico como Ataque furtivo, coloca la base del arma antes de ese extra. Una cláusula única que mezcle cortante y fuego debe producir un diagnóstico y conservar el daño nativo; corrige la ficha separando sus importes. El daño exclusivamente no físico y la base física sin dados conservan su resolución nativa, incluido el caso de la cerbatana con daño fijo: esta alpha todavía no les añade suplemento.

## Catálogo, manos y protección natural

Ejecuta `/arms catalog` y consulta War Pick, Quarterstaff, Longsword, Shuriken y Blunderbuss. Deben verse ocho grupos y cuarenta entradas. War Pick pertenece a `blunted`, conserva categoría marcial y su acción sigue causando daño perforante. Quarterstaff pertenece a `polearms` y es simple. Los dos nombres de campaña mantienen categoría y manos sin inventar estadísticas hasta que configures sus datos. Las maestrías de la ficha permanecen nativas.

Usa un arma versátil a una mano y luego a dos. El uso debe capturarse al lanzar cada acción y los dados deben ser los que proporcione la ficha. Haz un ataque a una mano y solicita daño a dos: el contexto anterior no debe usarse para convertir ese daño. Una etiqueta sin uso conocido debe mostrar `unknown`, sin deducir dos manos a partir del nombre. Importa una tabla `bladed_2h` de prueba: la consulta `/arms catalog "Longsword" 2h` debe mostrarla; a una mano debe seguir utilizando `bladed` si no existe `bladed_1h`.

Asigna una criatura explícitamente con `/arms armor "Diana" natural_scales 16` y una CA nativa conocida. La defensa adicional debe ser la CA efectiva menos 16. Prueba también `natural_hide`, `natural_shell` y `unarmored`. Ningún perfil debe añadir resistencias, modificar la CA de la ficha ni elegirse automáticamente por una CA alta. Las tres curvas naturales coinciden inicialmente con sus semillas cuero/malla/placas; cambiar una mediante una importación completa no debe alterar las otras. La distinción material entre laminada CA 17 y placas CA 18 dentro de `plate` sigue pendiente de columnas específicas; no es una función terminada de 0.3.1.

## Asociación y multijugador

Realiza ataques contra dos dianas con armaduras diferentes y resuelve cada daño por separado. Comprueba que no se intercambian calidades. Prueba dos ataques pendientes de la misma arma al mismo objetivo: debe mostrarse el diagnóstico de ambigüedad y mantenerse el daño nativo. Prueba `/arms bypass`, `/arms clear`, un daño sin ataque previo y un daño con varios objetivos. No debe reutilizarse silenciosamente una calidad anterior.

Conecta un jugador, repite desde su ficha el ataque y el daño, y comprueba que los puntos de golpe se actualizan una sola vez en el host. Intenta cambiar el modo e importar CSV desde el jugador: solo el director puede hacerlo. Cambia el perfil desde el host y verifica que el siguiente ataque del cliente usa los nuevos datos.

## Reglas y guardado

Comprueba las automatizaciones que realmente uses: crítico ampliado, objetivo paralizado, maestrías, dados de Sneak Attack, Smite y reacciones que cambien la defensa. Esta lista no afirma que todas estén automatizadas por el paquete. El daño y sus cláusulas deben conservar el contrato nativo; cualquier discrepancia requiere revisar la integración antes de utilizar esa combinación.

Importa `examples/table-format.csv`, asigna `training_sword`, cierra la campaña y ábrela de nuevo. La tabla, las asociaciones y el modo elegido deben persistir. Desactiva la extensión y comprueba que no ha alterado los campos de CA, las acciones de las fichas ni los puntos de golpe por otra vía que el daño aplicado durante las pruebas.

Si actualizas desde 0.2.0, verifica las asociaciones con `sword`, `mace`, `spear`, `axe` y `bow`: deben resolver sus tablas canónicas. Un CSV que incluya `sword` y `bladed` debe rechazarse sin guardar cambios. En lotes separados, el posterior debe sustituir la tabla completa; comprueba ese mismo orden después de recargar la campaña y revisa los perfiles presentes en `/arms tables`.

## Informe útil de una incidencia

Anota versión de Fantasy Grounds y del sistema 5E, host o jugador, lista de extensiones, modo, arma, defensor, comandos de configuración y secuencia que produjo el problema. Conserva el texto de `/arms status` y el error Lua si aparece. Distingue entre un cálculo de la tabla que no te guste y una asociación o aplicación incorrecta: el primero se ajusta en los datos; el segundo es un fallo de integración.
