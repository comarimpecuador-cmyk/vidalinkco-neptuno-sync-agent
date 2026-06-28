# NEPTUNO Sync Agent Phase 9A-1B Permanent Runbook

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
-ExternalIds       IDs NEPTUNO opcionales para prueba dirigida
-Eligibility       AllForAudit, ActiveSellable o ActiveSellableWithStock
-OnInvalidLive     Quarantine (default) o FailFast
-RunType           Bootstrap, Incremental (default) o Audit
-RetentionRuns     runs conservados; default 20
-Send              habilita explícitamente el POST
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

## Estado, cursors y evidencia retenida

No se crean payloads sueltos en la raíz. La estructura es:

```text
exports/neptuno-sync/
  state/
    fingerprints.json
    cursors.json
  runs/<syncRunId>/
    catalog-payload.json
    live-payload.json
    changed-products.json
    quarantine-items.json
    sync-summary.json
    sync-events.ndjson
    sync-warnings.ndjson
  latest/
    sync-summary.json
```

`RetentionRuns` conserva los runs más recientes y borra solamente directorios
viejos bajo `runs/`. Nunca borra `state/`. Quarantine es evidencia de calidad,
no basura; queda sujeto a la misma retención auditable del run.

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
`eligible-scan-fingerprint-fallback`: lectura elegible y salida solo de hashes
cambiados. Los high-watermarks permanecen `null` hasta una auditoría fiable.

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

Esta es una extensión aditiva de Fase 9A-1B; no reemplaza los endpoints CSV
documentados previamente. La URL configurada debe apuntar a un endpoint que
acepte explícitamente este contrato delta y responda con envelope:

```json
{ "ok": true, "data": {} }
```

No se debe usar `-Send` todavía ni hasta confirmar ese contrato en Vidalinkco.
El script no asume ni concatena rutas de endpoint. Vidalinkco recibirá staging y
deltas, no el universo completo de NEPTUNO en cada ejecución.

Contrato futuro, no ejecutar todavía:

```powershell
$env:VIDALINKCO_NEPTUNO_SYNC_URL = "https://host-autorizado.example/api/ruta-configurada"
$env:VIDALINKCO_NEPTUNO_SYNC_TOKEN = "valor-local-no-versionado"

.\scripts\sync-neptuno-catalog.ps1 `
  -OutputDirectory ".\exports\neptuno-sync" `
  -BodegaId 1 `
  -Mode All `
  -RunType Incremental `
  -Send
```

El envío agrega `Authorization: Bearer ...` e `Idempotency-Key`, usa timeout de
30 segundos y hasta tres intentos para errores transitorios. No envía cuando no
hay cambios.

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
```

El smoke usa fixture sintético, no abre SQL y no envía red. El envío exitoso se
simula con un switch interno no operativo. Valida Bootstrap, Incremental, Audit,
confirmación de state, separación catálogo/live, negativos, ExternalIds,
elegibilidad, FailFast, retención, Git ignore y seguridad de payload.

Salida esperada:

```text
NEPTUNO sync payload smoke passed.
PowerShell parser: OK
SELECT-only SQL: OK
Bootstrap and incremental fingerprints: OK
Dry-run preserves pending send delta: OK
Successful send confirms state: OK
Catalog/live delta separation: OK
Negative live quarantine and stock clamp: OK
ExternalIds and eligibility filters: OK
Audit no-send behavior: OK
FailFast policy: OK
Run retention and permanent state: OK
Git ignore for exports: OK
Payload safety: OK
Dry-run network isolation: OK
Send credential guards: OK
```

## Riesgos y próximos pasos

- Ejecutar Bootstrap una vez y revisar su run antes de usar Incremental.
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
- El vademécum permanece limitado a metadata no clínica.
