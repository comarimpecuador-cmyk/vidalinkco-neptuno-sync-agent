# NEPTUNO Sync Agent Phase 9A-5 Permanent Runbook

## Objetivo y alcance

`scripts/sync-neptuno-catalog.ps1` lee catálogo, precio y stock desde NEPTUNO
con consultas `SELECT`, construye snapshots JSON, calcula fingerprints
incrementales y deja evidencia local. Se ejecuta posteriormente en la PC
farmacia; no se ejecutó contra NEPTUNO desde la PC casa.

La fase alimenta integración operativa/staging. No crea, activa, publica ni
indexa automáticamente productos en Vidalinkco.

## Fuentes NEPTUNO confirmadas

- `in_item`: identificador, descripción, precio, IVA, clasificación y estado.
- `in_producto`: presentación, medida, concentración, fraccionamiento,
  fabricante y flags operativos.
- `in_item_bodega`: stock por bodega y habilitación.
- `in_bodega`: nombre de bodega mediante la columna confirmada `nombre`.
- `in_estado_item`: descripción del estado y permiso de venta.
- `in_nodo_clasif_1` / `in_nodo_clasif_2`: categoría y subcategoría.
- `in_fabricante` / `co_ente`: código y nombre del fabricante.
- `fa_vademecum` / `fa_seccion_vademecum`: solamente ID, descripción y nombres
  ordenados de secciones.

Los blobs `fa_vademecum.cabecera` y `fa_seccion_vademecum.contenido` no aparecen
en los SQL ni en los payloads.

`pa_item_catalogo` está identificado como catálogo de etiquetas, pero el repo
no confirma aún sus columnas exactas de relación. Por eso
`presentacionNombre`, `medidaNombre` y `concentracionNombre` permanecen `null`
en SQL real, mientras sus códigos sí se preservan. Resolver ese TODO requiere
una auditoría de esquema en la PC farmacia; no se debe adivinar el join.

## Parámetros

```text
-ConnectionString  opcional; SQL Server local, Integrated Security y read-only
-OutputDirectory   default <repo>/exports/neptuno-sync
-SourceKey         default neptuno-farmacia-universal
-BodegaId          default 1
-Mode              Catalog, Live o All; default All
-MaxProducts       límite opcional para pruebas controladas
-BatchSize         filas máximas por query y rama; default 500
-StartAfterExternalId  límite inferior inicial opcional para keyset
-MaxBatches        máximo de lotes en esta invocación; deja run resumible
-CommandTimeoutSeconds timeout SQL por lote; default 120
-ProgressEveryBatches frecuencia del progreso visible; default 1
-Resume            continúa el último run incompleto compatible
-ExternalIds       IDs NEPTUNO opcionales para prueba dirigida
-Eligibility       AllForAudit, ActiveSellable o ActiveSellableWithStock
-OnInvalidLive     Quarantine (default) o FailFast
-RunType           Bootstrap, Incremental (default) o Audit
-RetentionRuns     alias legado para minimo de exitosos; default 10
-RetentionEnabled  true por defecto; desactiva cleanup automatico si es false
-SuccessfulRunRetentionDays  default 7
-FailedRunRetentionDays      default 30
-MinimumSuccessfulRunsToKeep default 10
-MinimumFailedRunsToKeep     default 20
-PreserveFullPayloads        conserva payloads completos de runs completados
-PreserveFailedPayloads      default true
-CleanupDryRun               calcula cleanup al final sin borrar
-StaleRunningAfterHours      cleanup manual; default 24
-Send              habilita explícitamente el POST
-MaxSendItems      máximo para POST normal; default y máximo 1000
-InitialBaseline   habilita explícitamente el baseline enviado por chunks
-ChunkSize         elementos combinados por chunk; default 500, máximo 1000
-ChunkDelaySeconds pausa entre chunks enviados; default recomendado 5
-MaxChunkAttempts  intentos por chunk en cada invocación; default 8
-DryRun            explícito; sin -Send el dry-run es siempre true
-ApiUrl             parámetro o VIDALINKCO_NEPTUNO_SYNC_URL
-ApiToken           parámetro o VIDALINKCO_NEPTUNO_SYNC_TOKEN
-RebuildState      reconstruye baseline en Bootstrap/Audit, no en Incremental
```

El script rechaza `-Send -DryRun`. `-Send` exige URL HTTPS y token. Nunca
imprime el token ni la connection string. `Audit` rechaza siempre `-Send`.
`Incremental` exige un `state/fingerprints.json` compatible: si no existe, se
debe ejecutar primero `Bootstrap`.

## Tipos de ejecución permanentes

- `Bootstrap`: ejecución inicial o reconstrucción deliberada del baseline.
  Marca el universo leído como changed, crea fingerprints/cursors y no es la
  operación diaria.
- `Incremental`: modo permanente y default. Compara contra el estado local y
  escribe en los payloads solamente catálogo/live que cambió.
- `Audit`: diagnóstico amplio. Puede usar `AllForAudit`, genera evidencia y
  quarantine, nunca envía ni modifica el state permanente.

`ExternalIds` acepta un ID (`-ExternalIds 9102`), varios
(`-ExternalIds 9102,1982`) o puede omitirse. Se aplica trim, se eliminan vacíos
y duplicados. Si no queda ningún ID, el valor interno es `null`, no se agrega
filtro SQL y `externalIdsFilterApplied` queda `false`.

`MaxProducts` es solamente un recorte técnico. No es elegibilidad comercial.
`Eligibility` filtra oferta live; no elimina metadata del catálogo. En
particular, `ActiveSellableWithStock` exige stock normalizado positivo en live,
pero no define qué productos existen en el catálogo maestro.

`Mode Catalog` y `Mode Live` pueden calendarizarse por separado. Cada ejecución
actualiza solamente su rama de fingerprints/cursors y conserva intacta la otra.

## Bootstrap inicial en la PC farmacia

Desde la raíz del repositorio:

```powershell
.\scripts\sync-neptuno-catalog.ps1 `
  -OutputDirectory ".\exports\neptuno-sync" `
  -SourceKey "neptuno-farmacia-universal" `
  -BodegaId 1 `
  -Mode All `
  -Eligibility ActiveSellable `
  -RunType Bootstrap `
  -BatchSize 500 `
  -CommandTimeoutSeconds 120 `
  -DryRun
```

No repita Bootstrap como operación normal. Después use Incremental:

```powershell
.\scripts\sync-neptuno-catalog.ps1 `
  -OutputDirectory ".\exports\neptuno-sync" `
  -BodegaId 1 `
  -Mode All `
  -Eligibility ActiveSellableWithStock `
  -RunType Incremental `
  -BatchSize 500 `
  -CommandTimeoutSeconds 120 `
  -DryRun
```

Prueba dirigida del producto `9102`, sin podar fingerprints de otros IDs:

```powershell
.\scripts\sync-neptuno-catalog.ps1 `
  -OutputDirectory ".\exports\neptuno-sync" `
  -ExternalIds 9102 `
  -BodegaId 1 `
  -Mode All `
  -Eligibility AllForAudit `
  -RunType Audit `
  -DryRun
```

La connection string por defecto es:

```text
Data Source=localhost;Initial Catalog=NEPTUNO;Integrated Security=True;Encrypt=False;ApplicationIntent=ReadOnly
```

Aunque se reciba otra connection string, el script fuerza
`ApplicationIntent=ReadOnly`. Los dos SQL se validan contra comandos mutantes
antes de abrir la conexión.

Las queries operativas no dependen de `TRY_CONVERT` ni `TRY_CAST`, funciones no
disponibles en la versión de SQL Server observada en farmacia. El keyset compara
directamente la columna nativa numérica `i.id_item` con
`@StartAfterExternalId`. Para una consulta auxiliar, use también el tipo nativo
confirmado; no convierta texto arbitrario ni agregue `TRY_CONVERT`.

## Lotes, progreso y reanudación

Catálogo y live se leen por keyset ascendente (`externalId > cursor`) con
`TOP (@BatchSize)`. Cada rama mantiene su cursor independiente porque sus
universos pueden tener distinta densidad. `lastProcessedExternalId` es un
resumen; `catalogLastExternalId` y `liveLastExternalId` son los cursores
autoritativos del checkpoint.

Al completar cada lote, la consola muestra `syncRunId`, tipo, último ID,
filas vistas, cambios, quarantine y tiempo transcurrido. El script escribe de
forma atómica `runs/<syncRunId>/checkpoint.json` y conserva trabajo interno
acotado bajo `work/`. El estado reanudable acumulativo vive en un unico
`work/progress-state.json` reemplazable; no se crean snapshots acumulativos por
lote. Los NDJSON bajo `work/batches/` contienen solamente el lote
correspondiente. Al completar, compone los artefactos finales y elimina
`work/`.

Para una prueba controlada que se detenga luego de dos lotes:

```powershell
.\scripts\sync-neptuno-catalog.ps1 `
  -OutputDirectory ".\exports\neptuno-sync" `
  -RunType Bootstrap `
  -Mode All `
  -BatchSize 500 `
  -MaxBatches 2 `
  -DryRun
```

El run queda `interrupted`, no actualiza `state/` ni `latest/`. Para continuar,
repita los mismos argumentos operativos, quite `-MaxBatches` y agregue
`-Resume`:

```powershell
.\scripts\sync-neptuno-catalog.ps1 `
  -OutputDirectory ".\exports\neptuno-sync" `
  -RunType Bootstrap `
  -Mode All `
  -BatchSize 500 `
  -Resume `
  -DryRun
```

`-Resume` exige coincidencia de source, run type, mode, eligibility, bodega,
filtro de IDs y modalidad de envío. Reutiliza el `syncRunId`, `BatchSize`,
inicio y límite del checkpoint; no reprocesa lotes ya confirmados. Si se detiene
con `Ctrl+C`, el último checkpoint atómico puede conservar `running`; también es
elegible para `-Resume`. `StartAfterExternalId` sirve para una auditoría o
partición deliberada, no sustituye el checkpoint.

Un timeout o error deja el run `failed`, con summary/checkpoint parcial y sin
cambiar `state/` ni `latest/`. `latest/sync-summary.json` apunta exclusivamente
al último run `completed`.

Verificación operativa:

```powershell
$latest = Get-Content ".\exports\neptuno-sync\latest\sync-summary.json" -Raw | ConvertFrom-Json
$latest.status
Get-Content ".\exports\neptuno-sync\runs\$($latest.syncRunId)\checkpoint.json" -Raw

$current = Get-ChildItem ".\exports\neptuno-sync\runs" -Directory | Sort-Object Name -Descending | Select-Object -First 1
Get-Content (Join-Path $current.FullName "checkpoint.json") -Raw
```

El primer valor debe ser `completed`. El segundo bloque inspecciona el run más
reciente aunque esté `running`, `interrupted` o `failed`; no confunda ese run
con el puntero estable `latest`.

## Estado, cursors y evidencia retenida

No se crean payloads sueltos en la raíz. La estructura es:

```text
exports/neptuno-sync/
  state/
    fingerprints.json
    cursors.json
  runs/<syncRunId>/
    checkpoint.json
    catalog-payload.json
    live-payload.json
    changed-products.json
    quarantine-items.json
    artifact-manifest.json
    sync-summary.json
    sync-events.ndjson
    sync-warnings.ndjson
    work/                 # solo mientras running/interrupted/failed
      batches/*.ndjson
      progress-state.json
  latest/
    sync-summary.json
```

La retencion usa el criterio mas protector: un run se conserva si cumple el
criterio de edad o el criterio de cantidad minima. Por defecto:

- `completed`: conservar ultimos 7 dias o los 10 completados mas recientes.
- `failed`: conservar ultimos 30 dias o los 20 fallidos mas recientes.
- `running` activo e `interrupted`: no se eliminan automaticamente.
- `state/`, `latest/`, fingerprints y cursors nunca se eliminan.

Fase 2 agrega limpieza de deuda historica sin cambiar el runtime del sync:

- Un run con `sync-summary.json.completedAt` se considera `completed` aunque
  venga de un bootstrap legacy sin metadata moderna.
- `running` solo puede reclasificarse como `StaleRunning` en el cleanup manual
  si supera `-StaleRunningAfterHours`, la tarea `Vidalinkco NEPTUNO Sync` no
  esta `Running` y no hay `processId` activo en el checkpoint.
- `StaleRunning` e `interrupted` pueden compactar `work/progress/*.json`
  legacy conservando solo el snapshot mas reciente.
- El preview muestra `ClassifyStaleRun`, `DeleteLegacyPayload`,
  `CompactLegacyProgress` y `PreserveNewestProgressSnapshot`.

Al terminar un run `completed`, los payloads completos se consideran diagnostico
temporal y se podan salvo que se use `-PreserveFullPayloads`. Permanecen
`sync-summary.json`, `checkpoint.json`, eventos, warnings y
`artifact-manifest.json`. Los payloads de runs `failed` se conservan por defecto
para diagnostico (`-PreserveFailedPayloads $false` permite podarlos
explicitamente).

La limpieza automatica al final de un run es idempotente y tolerante a errores:
si un archivo esta bloqueado o una carpeta incompleta no puede borrarse, se
emite warning pero una sincronizacion exitosa no se convierte en fallida.

Preview operativo sin borrar nada:

```powershell
.\scripts\cleanup-neptuno-sync-exports.ps1
```

Aplicacion destructiva solo tras revisar el preview:

```powershell
.\scripts\cleanup-neptuno-sync-exports.ps1 -Apply
```

Para ajustar el umbral stale:

```powershell
.\scripts\cleanup-neptuno-sync-exports.ps1 -StaleRunningAfterHours 48
```

Carpetas historicas de smoke/test conocidas solo se incluyen si se pide
explicitamente:

```powershell
.\scripts\cleanup-neptuno-sync-exports.ps1 -IncludeHistoricalTestDirectories
```

`exports/local-audit` se reporta por separado y no se elimina automaticamente.
Con `-Apply`, el script aborta si la tarea programada
`Vidalinkco NEPTUNO Sync` esta `Running`.

Los fingerprints excluyen timestamps volátiles, normalizan strings con `Trim`,
mantienen `null` estable y ordenan propiedades antes de SHA-256. Con
`-MaxProducts` el estado no observado se conserva para evitar falsos cambios en
la próxima ejecución completa.

El catálogo usa fingerprint de datos maestros y excluye `precioOrigen`; cambios
de precio pertenecen al fingerprint live. En `Incremental`, `catalog-payload`
y `live-payload` contienen únicamente sus respectivos deltas. Bootstrap y Audit
pueden emitir snapshots completos.

El estado separa fingerprints observados (`catalog` / `live`) de fingerprints
confirmados por envío (`sentCatalog` / `sentLive`). Dry-run actualiza solamente
los observados, por lo que una revisión local nunca consume el delta pendiente
de Vidalinkco. Con `-Send`, ambos grupos se actualizan solo después de una
respuesta aceptada; un envío fallido conserva el estado anterior para permitir
reintento.

`state/cursors.json` registra `lastCatalogSyncAt`, `lastLiveSyncAt`,
`lastSuccessfulSendAt`, high-watermarks, estrategia y confianza de esquema. El
repo no confirma una columna global confiable como `aud_mod_fecha_hora` o
`fecha_modificacion` en las tablas principales. Las fechas de última venta,
compra, transacción o ajuste son eventos operativos parciales, no un cursor
completo. Por eso la estrategia actual es
`external-id-keyset-batches-with-fingerprint-fallback`: el ID ordena y permite
reanudar la lectura, mientras el fingerprint determina el delta real. Los
high-watermarks guardan el último ID recorrido por catálogo/live; no se
interpretan como timestamp de modificación ni reemplazan los fingerprints.

## Contrato de envío opt-in

El POST usa el contenido de `changed-products.json`:

```json
{
  "contractVersion": 2,
  "source": "neptuno",
  "sourceKey": "neptuno-farmacia-universal",
  "syncRunId": "neptuno-...",
  "idempotencyKey": "neptuno-...",
  "runType": "Incremental",
  "mode": "All",
  "capturedAt": "2026-06-28T00:00:00Z",
  "catalogChangedItems": [],
  "liveChangedItems": [],
  "quarantinedItems": {
    "total": 0,
    "negativePrice": 0,
    "negativeStockWarnings": 0
  }
}
```

Contrato v2 estable para consumidores:

- leer `catalogChangedItems` como array de cambios maestros;
- leer `liveChangedItems` como array de cambios operativos;
- leer `quarantinedItems` como resumen, no como payload de producto;
- no buscar los nombres legacy `catalogItems` / `liveItems` en este archivo;
- ambos arrays pueden estar vacíos en un Incremental sin cambios.

Esta es una extensión aditiva de Fase 9A-1B; no reemplaza los endpoints CSV
documentados previamente. La URL configurada debe apuntar a un endpoint que
acepte explícitamente este contrato delta y responda con envelope:

```json
{ "ok": true, "data": {} }
```

Fase 9A-4 incorpora el wrapper oficial
`scripts/run-neptuno-sync-production.ps1`. Lee exclusivamente
`Vidalinkco.NeptunoSyncAgent/appsettings.local.json`, toma
`NeptunoSyncAgent.VidalinkcoBaseUrl` y `NeptunoSyncAgent.ApiKey`, y construye
`{VidalinkcoBaseUrl}/api/integrations/neptuno/sync`.

El wrapper rechaza URL no HTTPS, el dominio `vidalinkco.example.com`, ApiKey
vacía y el placeholder `replace-with-local-api-key-only`. Nunca imprime la
ApiKey. El archivo local está ignorado por Git mediante `appsettings.local.json`
y no debe copiarse a documentación, argumentos de tarea ni logs.

Prueba dirigida sin POST:

```powershell
.\scripts\run-neptuno-sync-production.ps1 -DryRun -ExternalIds 9102
```

Ejecución productiva manual:

```powershell
.\scripts\run-neptuno-sync-production.ps1
```

Sin `-DryRun`, el wrapper usa `-Send`. Fija bodega 1, modo `All`, elegibilidad
`ActiveSellableWithStock`, run `Incremental`, lotes de 500 y timeout SQL de 120
segundos. `-ExternalIds` es opcional. `-MaxSendItems` tiene default 1000; si
`changedCatalogItems + changedLiveItems` lo supera, el script falla antes del
POST, no confirma fingerprints enviados y conserva evidencia del run fallido.
El envío agrega `Authorization: Bearer ...` e `Idempotency-Key`, usa timeout HTTP
de 30 segundos y hasta tres intentos para errores transitorios. No envía cuando
no hay cambios.

## Baseline inicial por chunks

Fase 9A-5 mantiene el guardrail normal en 1000. No se debe elevar
`MaxSendItems` para enviar decenas de miles de cambios en un único request. El
baseline inicial usa un modo explícito y exclusivo:

```powershell
.\scripts\run-neptuno-sync-production.ps1 -InitialBaseline -ChunkSize 500 -ChunkDelaySeconds 5
```

Ejecútelo una sola vez, en horario controlado y después de revisar el Bootstrap
y el dry-run. `InitialBaseline` no acepta `ExternalIds`, `MaxProducts`,
`StartAfterExternalId` ni `MaxBatches`: debe representar el conjunto completo.
Cada request contiene como máximo 1000 elementos combinados; el default
operativo es 500. Esto queda por debajo de los límites del contrato web: 5000
catálogo, 10000 live y 10000 combinados por request.

Cada chunk conserva en `runs/<parentSyncRunId>/chunks/`:

```text
manifest.json
chunk-000001/payload.json
chunk-000001/result.json
...
```

El manifiesto registra `parentSyncRunId`, tamaño, conteos, estado y número de
intentos. Cada payload tiene `syncRunId` e `idempotencyKey` únicos y
deterministas. Si el proceso falla después de que Vidalinkco aceptó un chunk,
la misma clave se reutiliza de forma segura y los chunks ya marcados `sent` no
se retransmiten.

Fase 9A-5B agrega throttle entre chunks y backoff específico para rate limit.
Después de cada chunk aceptado espera `ChunkDelaySeconds` antes del siguiente.
Ante HTTP 429 respeta `Retry-After` en segundos o fecha HTTP; si el header no
existe o es inválido, espera 120 segundos. Reintenta el mismo payload con la
misma `idempotencyKey` hasta `MaxChunkAttempts` por invocación. El
`attemptCount` del manifiesto permanece acumulado entre reanudaciones.

Progreso esperado:

```text
Sending chunk 31/102...
HTTP 429 on chunk 31; waiting 120 seconds before retry...
Sending chunk 31/102...
Chunk 31 sent
```

Reanudación del mismo baseline:

```powershell
.\scripts\run-neptuno-sync-production.ps1 -InitialBaseline -Resume
```

El resume conserva el `parentSyncRunId`, omite chunks `sent` y permite volver a
intentar chunks `failed`. No reinicie el baseline por un 429 ni ejecute el
resume inmediatamente en paralelo con otro proceso todavía activo.

Los fingerprints `sentCatalog`/`sentLive` se confirman únicamente cuando todos
los chunks terminan. Un fallo intermedio conserva checkpoint y manifiesto, no
actualiza el estado permanente y no reemplaza `latest`.

Secuencia operativa obligatoria:

1. Ejecutar `InitialBaseline` en horario controlado y verificar manifiesto,
   resultados y `sendStatus=sent-chunked`.
2. Ejecutar `run-neptuno-sync-production.ps1 -DryRun`; el delta esperado debe
   ser cero salvo cambios ocurridos después del baseline.
3. Habilitar el scheduler incremental normal, sin `InitialBaseline`.

Este flujo solo alimenta staging NEPTUNO. No crea, activa, publica ni indexa
`Product` público.

## Windows Task Scheduler

Antes de programar producción, complete una vez el Bootstrap documentado,
revise el dry-run del wrapper y confirme que la cuenta de Windows puede leer
NEPTUNO, el repositorio y `appsettings.local.json`.

Configure dos tareas separadas. No ejecute el sync completo cada cinco minutos:

1. `Vidalinkco NEPTUNO Sync`: cada 30 minutos, ejecuta
   `scripts/run-neptuno-sync-production.vbs` y realiza la revisión SQL completa.
2. `Vidalinkco NEPTUNO Heartbeat`: cada 5 minutos, ejecuta
   `scripts/run-neptuno-heartbeat-production.vbs`, lee solamente
   `exports/neptuno-sync/latest/sync-summary.json` y envía la señal operativa.

Acción del heartbeat oculto:

```text
Program/script: C:\Windows\System32\wscript.exe
Add arguments: "C:\ruta\vidalinkco-neptuno-sync-agent\scripts\run-neptuno-heartbeat-production.vbs"
Start in: C:\ruta\vidalinkco-neptuno-sync-agent
```

En ambas tareas seleccione `Do not start a new instance`. El heartbeat reutiliza
`Vidalinkco.NeptunoSyncAgent/appsettings.local.json`; no coloque URL, token ni
API key en argumentos del programador.

1. Abra **Task Scheduler** y seleccione **Create Task** (no Basic Task).
2. En **General**, use una cuenta de servicio con los permisos mínimos
   necesarios, active **Run whether user is logged on or not** y **Run with
   highest privileges** solo si el acceso local realmente lo exige.
3. En **Triggers**, cree la frecuencia operativa acordada y evite ejecuciones
   concurrentes.
4. En **Actions**, cree **Start a program** con:

   ```text
   Program/script: C:\Windows\System32\wscript.exe
   Add arguments: "C:\ruta\vidalinkco-neptuno-sync-agent\scripts\run-neptuno-sync-production.vbs"
   Start in: C:\ruta\vidalinkco-neptuno-sync-agent
   ```

5. En **Conditions**, configure red y energía según la PC farmacia.
6. En **Settings**, seleccione **Do not start a new instance** si la tarea ya
   está ejecutándose y habilite reintentos con una pausa prudente.
7. Guarde, ejecute manualmente una vez y verifique `Last Run Result`, historial
   y `exports/neptuno-sync/latest/sync-summary.json`.

Instalador opcional de tareas con launchers VBS:

```powershell
.\scripts\install-neptuno-scheduled-tasks.ps1 -WhatIf
.\scripts\install-neptuno-scheduled-tasks.ps1
```

Los launchers VBS no cambian la logica del agente: invocan los wrappers
PowerShell existentes con ventana oculta y devuelven el exit code al Scheduler.

No agregue URL ni ApiKey en los argumentos de la tarea. Para una validación
programada sin envío, agregue únicamente `-DryRun`; para una prueba dirigida,
agregue `-DryRun -ExternalIds 9102`.

## Datos sincronizados

Catálogo:

- ID, nombres y precio de origen.
- IVA, categoría, subcategoría y estado de origen.
- permiso de venta.
- códigos y nombres disponibles de presentación, medida y concentración.
- unidades/fracciones por caja cuando existe el dato.
- fabricante/laboratorio y flags de genérico/restricción/crónico/médico.
- ID/nombre del vademécum y nombres de sus secciones como metadata.

Estado vivo:

- producto, source key y bodega.
- precio actual, stock unidad y stock fracción.
- estado, permiso de venta e IVA de origen.
- timestamp de captura y raw operativo mínimo de IVA/bodega habilitada.

Precio negativo bloquea el live item con `NEGATIVE_PRICE` y lo deja en
`quarantine-items.json`; el catálogo puede conservar su metadata. Stock negativo
no detiene el run: `stockUnidad`/`stockFraccion` se limitan a cero y los valores
fuente quedan en `rawOperativo` con `NEGATIVE_STOCK_CLAMPED`. El warning aparece
en quarantine, `sync-events.ndjson` y `sync-warnings.ndjson`.

`ActiveSellable` excluye señales explícitas `puedeVender=false` o bodega
deshabilitada, pero permite stock cero. `ActiveSellableWithStock` añade stock
normalizado positivo. `AllForAudit` no aplica elegibilidad operativa, aunque
precio negativo sigue bloqueado del payload live.

## Datos excluidos

- blobs, bytes y archivos binarios.
- cabecera o contenido del vademécum.
- indicaciones, dosis, contraindicaciones u otro texto clínico decodificado.
- costos, márgenes, utilidad o datos financieros internos.
- credenciales, tokens, licencias, seriales o connection strings.
- decisiones automáticas de publicación, activación o indexación.

El texto clínico del vademécum queda pendiente de un decoder oficial o un
contrato documentado por el proveedor, seguido de revisión humana.

## Smoke local en la PC casa

```powershell
.\scripts\smoke-neptuno-sync-payload.ps1
.\scripts\smoke-neptuno-sync-retention.ps1
.\scripts\smoke-run-neptuno-sync-production.ps1
.\scripts\smoke-neptuno-heartbeat-production.ps1
.\scripts\smoke-neptuno-initial-baseline.ps1
```

El smoke usa fixture sintético, no abre SQL y no envía red. El envío exitoso y
el timeout se simulan con switches internos no operativos. Valida Bootstrap,
Incremental, Audit, keyset por lotes, checkpoint, interrupción/reanudación,
aislamiento de fallos, `StartAfterExternalId`, confirmación de state, separación
catálogo/live, negativos, ExternalIds, retención y seguridad de payload.
El segundo smoke prueba la retencion: state/latest protegidos, run activo
preservado, edad/cantidad minima, dry-run/apply, archivo bloqueado, rechazo de
rutas externas e idempotencia.
El tercer smoke prueba el wrapper con configuración temporal: configuración
válida, rechazo del dominio example, rechazo del ApiKey placeholder, aislamiento
del token y `ExternalIds 9102` en dry-run. No lee ni modifica la configuración
local real.
El cuarto smoke valida el wrapper de heartbeat sin SQL ni full sync.
El quinto smoke genera 1200 elementos sintéticos y valida tres chunks
`500/500/200`, identidades únicas, máximo de 1000 por request, fallo reanudable,
no retransmisión de chunks aceptados, transición a incremental y permanencia
del guardrail no chunked. También simula HTTP 429 en chunk 2 con `Retry-After`,
verifica la espera, el reintento con la misma identidad y el progreso sin token.

Salida esperada:

```text
NEPTUNO sync payload smoke passed.
PowerShell parser: OK
SELECT-only SQL: OK
Bootstrap and incremental fingerprints: OK
Keyset batching, checkpoint, resume and timeout isolation: OK
Dry-run preserves pending send delta: OK
Successful send confirms state: OK
Catalog/live delta separation: OK
Negative live quarantine and stock clamp: OK
ExternalIds and eligibility filters: OK
Missing and empty ExternalIds binding: OK
Audit no-send behavior: OK
FailFast policy: OK
Run retention and permanent state: OK
StartAfterExternalId lower bound: OK
Git ignore for exports: OK
Payload safety: OK
Dry-run network isolation: OK
Send credential guards: OK
```

## Riesgos y próximos pasos

- Ejecutar Bootstrap una vez y revisar su run antes de usar Incremental.
- Mantener `BatchSize=500` inicialmente y ajustar solo con evidencia de tiempo/carga.
- Reanudar runs incompletos antes de iniciar otro Bootstrap sobre la misma salida.
- No ejecutar otro `InitialBaseline` mientras exista uno fallido o incompleto;
  reanudar el mismo parent run.
- Usar `-MaxProducts` solo en una salida de prueba o Audit; no como filtro de negocio.
- Revisar payloads y nombres de campos contra resultados reales.
- Resolver el TODO de `pa_item_catalogo` mediante auditoría de esquema.
- Confirmar el endpoint delta y su Zod/DTO antes de habilitar `-Send`.
- No versionar `exports/`, estados, eventos ni secretos.
- Mantener publicación y activación como decisiones humanas separadas.

## Resumen ADN

- Se reutilizan tablas, joins, helper SQL y contratos auditados del repo.
- La lectura SQL es SELECT-only y `ApplicationIntent=ReadOnly`.
- El estado incremental es local y no altera NEPTUNO.
- La salida operacional no reemplaza el SSOT público de productos.
- El envío es opt-in y no existe publicación automática.
- El wrapper de producción centraliza configuración local, parámetros y límite
  pre-POST sin variables de entorno manuales.
- El baseline chunked conserva idempotencia por request y confirma fingerprints
  enviados solo al completar todos los chunks.
- El vademécum permanece limitado a metadata no clínica.
