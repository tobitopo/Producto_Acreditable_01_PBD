# Efest · Historias de usuario del fork académico SQL Server

Las historias especifican el comportamiento esperado del proyecto del curso. Los nombres de tablas, claves y vistas corresponden al [modelo conceptual](02-modelo-conceptual.md).

## RF01 — Crear, desbloquear y bloquear la bóveda

Como titular de una bóveda, quiero crearla con una contraseña maestra y controlar su desbloqueo, para que solo mi cliente pueda descifrar su contenido.

1. **Dado** un titular registrado, **cuando** crea una bóveda, **entonces** SQL Server guarda una fila asociada al titular con un salt aleatorio de 16 bytes, los parámetros de Argon2id y una marca de verificación cifrada con su nonce de 24 bytes. Ni la contraseña maestra ni la clave derivada llegan al servidor.
2. **Dada** una bóveda vacía con parámetros válidos, **cuando** el titular introduce la contraseña correcta, **entonces** el cliente deriva la clave con Argon2id, autentica la marca y desbloquea esa bóveda.
3. **Dada** una bóveda bloqueada, **cuando** se usa una contraseña incorrecta o falla la autenticación de la marca, **entonces** el cliente devuelve el mismo error genérico en ambos casos y entrega cero secretos.
4. **Dada** una sesión desbloqueada, **cuando** el titular la bloquea, **entonces** el cliente purga la clave y los secretos visibles, y toda solicitud de revelado requiere otro desbloqueo.

**Justificación relacional.** La FK `Vault.owner_id` identifica al titular en `VaultUser.user_id`. La PK `Vault.vault_id` identifica el conjunto de `salt`, `ops_limit`, `mem_limit_kib`, `check_ciphertext` y `check_nonce` que corresponde a esa bóveda.

## RF02 — Administrar y revelar credenciales

Como titular de una bóveda, quiero crear, consultar, editar y eliminar credenciales, para mantener mis cuentas al día y revelar una contraseña solo cuando la necesite.

1. **Dada** una bóveda desbloqueada, **cuando** guardo una credencial con título y contraseña, **entonces** se crea una fila en mi bóveda con la contraseña cifrada en el cliente mediante XChaCha20-Poly1305 y un nonce nuevo de 24 bytes.
2. **Dadas** dos credenciales propias, **cuando** consulto el listado y pido revelar una por su identificador, **entonces** el listado devuelve dos resúmenes sin secretos y la operación de revelado entrega solo la contraseña solicitada. Un identificador de otra bóveda no devuelve ningún secreto.
3. **Dada** una credencial existente, **cuando** edito su título en la ficha y cambio su contraseña desde el historial (RF04), **entonces** conserva su identificador, el resumen muestra el título actualizado y el siguiente revelado devuelve la nueva contraseña.
4. **Dada** una credencial con datos asociados, **cuando** confirmo su eliminación, **entonces** desaparece del resumen, su identificador ya no permite revelarla y quedan cero filas dependientes en el puente de etiquetas, el historial y la configuración TOTP. Las demás credenciales conservan sus datos.
5. **Dadas** dos credenciales con título y contraseña, **cuando** guardo una con URL y la otra sin ella, **entonces** la ficha de la primera muestra la URL guardada y la segunda se guarda con `Credential.url` en `NULL`.

**Justificación relacional.** `Credential.vault_id` referencia a `Vault.vault_id`. La vista `vw_CredentialSummary` proyecta los metadatos de lectura. La operación de revelado accede a `Credential.password_ciphertext` y `Credential.nonce` por credencial y bóveda autorizadas. El borrado respeta las FK de `CredentialTag`, `CredentialHistory` y `TotpConfig` en una transacción.

## RF03 — Clasificar por categoría y etiquetas

Como titular de una bóveda, quiero asignar una categoría opcional y varias etiquetas a cada credencial, para organizar mis cuentas por servicio y por contexto de uso.

1. **Dada** una credencial sin categoría, **cuando** le asigno una y después la sustituyo por otra, **entonces** queda asociada solo a la segunda. Al retirar la categoría, la credencial sigue disponible.
2. **Dadas** dos credenciales de la misma bóveda, **cuando** asigno dos etiquetas a la primera y comparto una de ellas con la segunda, **entonces** se conservan dos etiquetas y tres pares distintos de credencial y etiqueta. Repetir una asignación mantiene esos tres pares.
3. **Dadas** dos bóvedas, **cuando** intento asignar a una credencial una categoría o etiqueta de la otra, **entonces** la base rechaza la asignación y conserva la clasificación anterior.

**Justificación relacional.** La FK opcional `Credential.category_id` implementa la relación 1:N con `Category`. Las dos FK de `CredentialTag` forman su PK compuesta y materializan la relación N:M entre `Credential` y `Tag`. La asignación comprueba el `vault_id` de ambos extremos.

## RF04 — Conservar las contraseñas anteriores

Como titular de una bóveda, quiero que los cambios de contraseña generen un historial automático, para conservar las versiones anteriores de cada cuenta.

1. **Dada** una credencial sin historial, **cuando** cambio dos veces su contraseña, **entonces** hay dos versiones anteriores con sus respectivos cifrados, nonces y fechas de sustitución UTC, y la última contraseña queda vigente.
2. **Dada** una credencial, **cuando** modifico únicamente su título o usuario, **entonces** el número de versiones anteriores permanece igual.
3. **Dada** una actualización de contraseña, **cuando** falla la escritura de la nueva versión después de archivar la anterior, **entonces** SQL Server revierte la transacción. La contraseña vigente y el número de filas históricas coinciden con los valores previos.

**Justificación relacional.** `CredentialHistory.credential_id` referencia a `Credential.credential_id` en una relación 1:N. Una transacción archiva el par cifrado y nonce anterior con `replaced_at` y sustituye el par vigente.

## RF05 — Auditar accesos y operaciones críticas

Como responsable de auditoría, quiero reconstruir quién accedió a una bóveda y qué operaciones realizó, para revisar su uso sin consultar secretos.

1. **Dado** un usuario conocido, **cuando** inicia sesión y después desbloquea una bóveda, **entonces** se generan dos eventos con su identificador de actor e instante UTC. El evento `login` puede carecer de bóveda y `unlock` identifica la bóveda desbloqueada.
2. **Dada** una creación, edición, revelado o exportación completada, **cuando** reviso su evento, **entonces** encuentro la acción correspondiente (`create`, `update`, `reveal` o `export`), el actor, la bóveda, el tipo e identificador del objeto y el instante UTC. El evento contiene cero valores de credenciales.
3. **Dado** un evento existente, **cuando** un rol de aplicación intenta modificarlo o eliminarlo, **entonces** SQL Server deniega la operación. Eliminar posteriormente la credencial referenciada conserva el evento y su identificador histórico de destino.

**Justificación relacional.** Cada fila de `AuditLog` tiene una PK propia y FK a `VaultUser` y, cuando corresponde, a `Vault`. El par `target_type` y `target_id` identifica el objeto en el momento del evento. Los permisos de inserción y la ausencia de borrado en cascada preservan el registro.

## RF06 — Gestionar notas seguras y TOTP

Como titular de una bóveda, quiero guardar notas privadas y configurar el segundo factor de mis cuentas, para recuperar una nota o generar un código TOTP desde el cliente desbloqueado.

1. **Dada** una bóveda desbloqueada, **cuando** creo una nota y edito su texto, **entonces** cada escritura guarda el contenido cifrado con un nonce nuevo. El listado devuelve solo la bóveda, el identificador de nota y el título.
2. **Dada** una nota propia, **cuando** la abro por identificador, **entonces** el cliente descifra su texto vigente. Una vez eliminada, ese identificador devuelve cero notas.
3. **Dada** una credencial sin TOTP, **cuando** configuro la semilla, el algoritmo, los dígitos y el periodo, **entonces** queda una configuración vinculada a esa credencial. SQL Server conserva la semilla cifrada con su nonce y el cliente puede generar el código con los parámetros guardados.
4. **Dada** una credencial con TOTP, **cuando** sustituyo la configuración y después la desactivo, **entonces** queda una única configuración con los parámetros nuevos tras la sustitución y ninguna tras la desactivación. La credencial sigue disponible.

**Justificación relacional.** `SecureNote.vault_id` vincula cada nota a `Vault`. La vista `vw_SecureNoteSummary` excluye el texto cifrado y su nonce. `TotpConfig.credential_id` es a la vez PK y FK a `Credential`, lo que limita la configuración a una por credencial.

## RF07 — Buscar y filtrar sin exponer secretos

Como titular de una bóveda, quiero filtrar mis credenciales por título, usuario, categoría y etiquetas, para localizar una cuenta sin revelar su contraseña.

1. **Dadas** varias credenciales que comparten título, usuario o categoría, **cuando** combino esos tres filtros, **entonces** el resultado contiene solo las credenciales de mi bóveda que cumplen las tres condiciones. Al omitir la categoría, también pueden aparecer las credenciales sin clasificar.
2. **Dada** una credencial con dos etiquetas seleccionadas, **cuando** busco coincidencias con cualquiera de ellas, **entonces** la credencial aparece exactamente una vez y las credenciales sin ninguna coincidencia quedan fuera.
3. **Dadas** dos bóvedas con metadatos idénticos, **cuando** busco desde una de ellas con el rol de listado, **entonces** obtengo solo identificadores de la bóveda autorizada y las columnas del DTO de resumen. La consulta devuelve cero contraseñas, blobs o nonces y el rol carece de lectura directa de las tablas base.
4. **Dada** una credencial que contiene el texto «portal» solo en la URL, **cuando** busco «portal» en el campo Título o en el campo Usuario, **entonces** la credencial queda fuera del resultado.

**Justificación relacional.** `vw_CredentialSummary` conserva una fila por `Credential`, con su `Category` opcional. Los JOIN entre `CredentialTag` y `Tag` sustentan `vw_CredentialTagSummary`. El filtro comprueba si existe una asignación coincidente en la misma bóveda, para evitar duplicados. Los índices sobre metadatos y claves del puente permiten resolver la búsqueda sin leer secretos.

## RF08 — Exportar un respaldo auditable

Como titular de una bóveda, quiero exportar un respaldo estructurado de mis datos cifrados, para conservar una copia coherente de mis cuentas y sus relaciones.

1. **Dadas** dos bóvedas con datos, **cuando** exporto una de ellas, **entonces** el paquete contiene su identificador, la referencia al titular, los parámetros KDF, la marca de verificación y las filas propias de credenciales, historial, categorías, etiquetas, asignaciones, notas y TOTP. La comparación por identificador arroja cero filas de la otra bóveda.
2. **Dado** un cambio de contraseña concurrente con la exportación, **cuando** comparo el respaldo con el estado anterior y posterior al cambio, **entonces** la contraseña vigente y su historial corresponden juntos a uno de esos dos estados y todas las asignaciones de etiquetas apuntan a objetos incluidos.
3. **Dados** secretos con valores de prueba conocidos, **cuando** verifico el paquete, **entonces** cada carga conserva el cifrado autenticado y el nonce de la versión respaldada y el cliente puede descifrarla con la contraseña maestra correcta. El paquete excluye los valores secretos en claro, la contraseña maestra y la clave derivada.
4. **Dada** una exportación solicitada, **cuando** el sistema entrega el respaldo, **entonces** existe un evento `export` con el actor, el instante UTC y la bóveda como destino. Si el registro del evento falla, el sistema no entrega el paquete.

**Justificación relacional.** El respaldo parte de `Vault` y de su titular en `VaultUser`. Una lectura consistente en SQL Server sigue las FK que vinculan la bóveda con `Credential`, `CredentialHistory`, `Category`, `Tag`, `CredentialTag`, `SecureNote` y `TotpConfig`. Los identificadores preservan las relaciones del modelo. La operación usa una ruta de exportación autorizada y registra su evento en `AuditLog`.
