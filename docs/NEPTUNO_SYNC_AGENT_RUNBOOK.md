# NEPTUNO Sync Agent Phase 9A-1 Runbook

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
-Send              habilita explícitamente el POST
-DryRun            explícito; sin -Send el dry-run es siempre true
-ApiUrl             parámetro o VIDALINKCO_NEPTUNO_SYNC_URL
-ApiToken           parámetro o VIDALINKCO_NEPTUNO_SYNC_TOKEN
-RebuildState      ignora fingerprints anteriores
```

El script rechaza `-Send -DryRun`. `-Send` exige URL HTTPS y token. Nunca
imprime el token ni la connection string.

## Dry-run en la PC farmacia

Desde la raíz del repositorio:

```powershell
.\scripts\sync-neptuno-catalog.ps1 `
  -OutputDirectory ".\exports\neptuno-sync" `
  -SourceKey "neptuno-farmacia-universal" `
  -BodegaId 1 `
  -Mode All `
  -DryRun
```

Prueba acotada:

```powershell
.\scripts\sync-neptuno-catalog.ps1 `
  -OutputDirectory ".\exports\neptuno-sync-test" `
  -BodegaId 1 `
  -Mode All `
  -MaxProducts 10 `
  -DryRun `
  -RebuildState
```

La connection string por defecto es:

```text
Data Source=localhost;Initial Catalog=NEPTUNO;Integrated Security=True;Encrypt=False;ApplicationIntent=ReadOnly
```

Aunque se reciba otra connection string, el script fuerza
`ApplicationIntent=ReadOnly`. Los dos SQL se validan contra comandos mutantes
antes de abrir la conexión.

## Salidas locales

Dentro de `OutputDirectory`:

- `catalog-payload.json`: snapshot completo de catálogo para el modo habilitado.
- `live-payload.json`: snapshot completo de precio/stock para el modo habilitado.
- `changed-products.json`: contrato delta que contiene solamente items cuyo
  fingerprint es nuevo o cambió.
- `sync-summary.json`: conteos y estado de dry-run/envío, sin secretos.
- `sync-events.ndjson`: un evento sanitizado por ejecución.
- `state/fingerprints.json`: hashes por producto y por producto/bodega.

Los fingerprints excluyen timestamps volátiles, normalizan strings con `Trim`,
mantienen `null` estable y ordenan propiedades antes de SHA-256. Con
`-MaxProducts` el estado no observado se conserva para evitar falsos cambios en
la próxima ejecución completa.

El estado separa fingerprints observados (`catalog` / `live`) de fingerprints
confirmados por envío (`sentCatalog` / `sentLive`). Dry-run actualiza solamente
los observados, por lo que una revisión local nunca consume el delta pendiente
de Vidalinkco. Con `-Send`, ambos grupos se actualizan solo después de una
respuesta aceptada; un envío fallido conserva el estado anterior para permitir
reintento.

## Contrato de envío opt-in

El POST usa el contenido de `changed-products.json`:

```json
{
  "source": "neptuno",
  "sourceKey": "neptuno-farmacia-universal",
  "syncRunId": "neptuno-...",
  "mode": "All",
  "capturedAt": "2026-06-28T00:00:00Z",
  "catalogItems": [],
  "liveItems": []
}
```

Esta es una extensión aditiva de Fase 9A-1; no reemplaza los endpoints CSV
documentados previamente. La URL configurada debe apuntar a un endpoint que
acepte explícitamente este contrato delta y responda con envelope:

```json
{ "ok": true, "data": {} }
```

No se debe usar `-Send` hasta confirmar ese contrato en Vidalinkco. El script no
asume ni concatena rutas de endpoint.

Configurar secretos solo en la sesión local de PowerShell:

```powershell
$env:VIDALINKCO_NEPTUNO_SYNC_URL = "https://host-autorizado.example/api/ruta-configurada"
$env:VIDALINKCO_NEPTUNO_SYNC_TOKEN = "valor-local-no-versionado"

.\scripts\sync-neptuno-catalog.ps1 `
  -OutputDirectory ".\exports\neptuno-sync" `
  -BodegaId 1 `
  -Mode All `
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

El smoke usa fixture sintético, no abre SQL y no envía red. Ejecuta tres ciclos:
estado nuevo, estado sin cambios y cambio controlado. Valida parser, SQL
read-only, estructura, fingerprints, changed-products, metadata plana de
secciones, ausencia de secretos/blobs y aislamiento de red en dry-run.

Salida esperada:

```text
NEPTUNO sync payload smoke passed.
PowerShell parser: OK
SELECT-only SQL: OK
Deterministic fingerprints: OK
Dry-run preserves pending send delta: OK
Changed-products detection: OK
Payload safety: OK
Dry-run network isolation: OK
Send credential guards: OK
```

## Riesgos y próximos pasos

- Ejecutar primero `-MaxProducts 10 -DryRun` en la PC farmacia.
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
