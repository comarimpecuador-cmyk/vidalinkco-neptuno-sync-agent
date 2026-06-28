# NEPTUNO Sync Agent Contract

## Proposito

El agente Vidalinkco NEPTUNO Sync Agent corre en una PC Windows de farmacia para preparar la sincronizacion segura entre NEPTUNO SQL Server y Vidalinkco por HTTPS.

El runner .NET inicial implementa configuracion segura, heartbeat, dry-run,
envio manual de stock/precio desde CSV local y envio manual de catalogo desde
CSV local. Ese runner no conecta todavia a SQL Server ni instala Windows
Service.

La Fase 9A-1B agrega, de forma separada y aditiva, el script PowerShell
`scripts/sync-neptuno-catalog.ps1`. Este script consulta SQL Server con
`ApplicationIntent=ReadOnly` y SQL `SELECT`-only, genera snapshots y delta
incremental local, y permanece en dry-run salvo `-Send` explicito. Su operación
permanente es `Bootstrap` una sola vez, seguida por `Incremental`; `Audit` nunca
envía ni altera el state. No reemplaza los runners CSV ni sus endpoints.

## Contrato delta Fase 9A-1B

El artefacto `changed-products.json` y el body opcional de `-Send` usan:

```json
{
  "contractVersion": 2,
  "source": "neptuno",
  "sourceKey": "neptuno-farmacia-universal",
  "syncRunId": "neptuno-20260628T000000000Z-12345678",
  "idempotencyKey": "neptuno-20260628T000000000Z-12345678",
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

`catalogChangedItems` contiene solamente cambios de datos maestros y metadata
factual; su fingerprint excluye precio. `liveChangedItems` contiene solamente
cambios de precio/stock/estado por bodega. Ninguno admite `fa_vademecum.cabecera`,
`fa_seccion_vademecum.contenido`, bytes ni texto clinico decodificado.

Estos nombres son el contrato v2 estable de `changed-products.json`; ambos son
arrays y pueden estar vacios. Los nombres legacy `catalogItems` y `liveItems`
no forman parte del contrato delta v2. `ExternalIds` ausente o normalizado sin
valores significa sin filtro y se reporta como `externalIdsFilterApplied=false`
en el summary del run.

Precio negativo queda bloqueado del live delta con `NEGATIVE_PRICE`. Stock
negativo se normaliza a cero y conserva sus valores fuente con
`NEGATIVE_STOCK_CLAMPED`. Quarantine es evidencia retenida por run, no dato
publicable.

El estado permanente vive bajo `OutputDirectory/state`: `fingerprints.json`
separa observado de enviado y `cursors.json` registra sync/send timestamps,
high-watermarks, estrategia y confianza. No hay una columna global de auditoria
confirmada en las tablas principales; la estrategia vigente es
`eligible-scan-fingerprint-fallback` con high-watermarks nulos.

El endpoint delta no se hardcodea: debe proporcionarse por `-ApiUrl` o
`VIDALINKCO_NEPTUNO_SYNC_URL`, debe usar HTTPS y debe responder con el envelope
estandar. Hasta que Vidalinkco confirme un endpoint/DTO compatible, el contrato
queda en dry-run y no debe usarse `-Send`. Detalle operativo:
`docs/NEPTUNO_SYNC_AGENT_RUNBOOK.md`.

## Endpoints Vidalinkco

Base URL configurable por ambiente:

- `NeptunoSyncAgent:VidalinkcoBaseUrl`

Header obligatorio para endpoints de integracion:

- `x-vidalinkco-integration-key: <api-key-local>`

Endpoints:

- `POST /api/integrations/neptuno/heartbeat`
- `POST /api/integrations/neptuno/stock-price`
- `POST /api/integrations/neptuno/catalog`

Todas las respuestas deben usar envelope consistente:

```json
{ "ok": true, "data": {} }
```

```json
{ "ok": false, "error": "mensaje" }
```

## Payload heartbeat

Endpoint:

```http
POST /api/integrations/neptuno/heartbeat
```

Payload:

```json
{
  "agentId": "farmacia-principal-neptuno-001",
  "source": "neptuno",
  "machineName": "PC-FARMACIA-01",
  "version": "0.1.0",
  "occurredAtUtc": "2026-06-22T02:15:00Z",
  "status": "online",
  "mode": "dry-run",
  "dryRun": true,
  "batchSize": 100,
  "intervals": {
    "heartbeatSeconds": 300,
    "stockSyncSeconds": 900
  },
  "capabilities": {
    "heartbeat": true,
    "stockPriceFuture": true,
    "catalogFuture": true,
    "csvImportFuture": true,
    "sqlServerEnabled": false
  },
  "runtime": {
    "osDescription": "Microsoft Windows 10.0.19045",
    "processArchitecture": "X64",
    "dotnetVersion": "10.0.0"
  }
}
```

Respuesta esperada:

```json
{
  "ok": true,
  "data": {
    "acceptedAtUtc": "2026-06-22T02:15:01Z",
    "message": "ok"
  }
}
```

## Payload stock-price CSV

Endpoint:

```http
POST /api/integrations/neptuno/stock-price
```

Payload:

```json
{
  "source": "neptuno",
  "agentId": "farmacia-principal-neptuno-001",
  "syncRunId": "opcional-20260622T022000Z",
  "items": [
    {
      "externalId": "NEP-000123",
      "nombreOriginal": "Producto ejemplo",
      "precioActual": 9.99,
      "stockUnidad": 12,
      "stockFraccion": 0,
      "bodegaExternalId": "BODEGA-PRINCIPAL",
      "estadoExternalId": "1",
      "estadoNombre": "ACTIVO",
      "puedeVender": true,
      "aplicaIvaOrigen": "S",
      "ivaOrigenId": "IVA-12",
      "barcode": "7700000000012",
      "barcodeAlt": null,
      "rawPayload": {
        "externalId": "NEP-000123",
        "nombreOriginal": "Producto ejemplo",
        "precioActual": "9.99",
        "aplicaIvaOrigen": "S",
        "ivaOrigenId": "IVA-12",
        "precioOrigenTipo": "BASE",
        "precioFinalCalculado": null
      },
      "syncedAt": "2026-06-22T02:19:30Z"
    }
  ]
}
```

Respuesta esperada:

```json
{
  "ok": true,
  "data": {
    "acceptedAtUtc": "2026-06-22T02:20:01Z",
    "message": "ok",
    "acceptedItems": 1
  }
}
```

Reglas:

- `externalId` debe ser estable desde NEPTUNO.
- `nombreOriginal` debe contener el nombre original desde NEPTUNO o desde CSV.
- `precioActual` no puede ser negativo.
- `precioActual` representa el precio operativo recibido o calculado desde NEPTUNO para monitoreo externo.
- `stockUnidad` no puede ser negativo.
- `stockFraccion` no puede ser negativo.
- `bodegaExternalId` identifica la bodega origen si existe.
- `estadoExternalId` es opcional; si el CSV no lo trae, el agente envia `null`.
- `estadoNombre` usa la columna `estadoNombre` o el alias `status`.
- `puedeVender` usa la columna `puedeVender` o el alias `canSell`.
- `aplicaIvaOrigen` es texto opcional; usa la columna `aplicaIvaOrigen` o el alias `appliesIva` y preserva valores como `S`, `N`, `true`, `false` o `null`.
- `ivaOrigenId` usa la columna `ivaOrigenId` o el alias `ivaId` y preserva `in_item.id_iva` como texto.
- `barcodeAlt` usa la columna `barcodeAlt` o el alias `alternateBarcode`.
- `rawPayload` contiene los valores originales leidos desde el CSV para auditoria, incluyendo precio original, `aplicaIvaOrigen`, `ivaOrigenId`, `precioOrigenTipo` si se conoce (`BASE` o `FINAL`) y cualquier precio final calculado si existiera.
- `items.length` no debe superar `SendBatchSize`.
- SQL Server real no se consulta en esta fase.
- El origen de datos de esta fase es un CSV local controlado por `StockPriceCsvPath`.
- En esta fase la integracion escribe estado externo en `ExternalProduct` / `ProductLiveState`; no modifica productos publicos.
- `ProductLiveState.precioActual` no debe usarse automaticamente como precio de checkout publico sin una capa de adaptacion.
- `precioActual` no publica, no indexa y no modifica `Product`.
- No se cambia el significado de `Product.precio` en Vidalinkco.
- Cuando mas adelante se cree un `Product` publico desde NEPTUNO, debe existir una capa de conversion: si NEPTUNO entrega precio base, mapear a `Product.precio` base y `Product.iva`; si entrega precio final, convertirlo o marcarlo correctamente para no duplicar IVA.

## Formato CSV stock/precio

Columnas recomendadas:

```csv
externalId,nombreOriginal,precioActual,stockUnidad,stockFraccion,bodegaExternalId,estadoExternalId,estadoNombre,puedeVender,aplicaIvaOrigen,ivaOrigenId,precioOrigenTipo,precioFinalCalculado,barcode,barcodeAlt,syncedAt
```

Alias amigables aceptados para CSV:

- `name` -> `nombreOriginal`
- `price` -> `precioActual`
- `warehouseExternalId` -> `bodegaExternalId`
- `status` -> `estadoNombre`
- `canSell` -> `puedeVender`
- `appliesIva` -> `aplicaIvaOrigen`
- `ivaId` -> `ivaOrigenId`
- `alternateBarcode` -> `barcodeAlt`

Reglas del lector:

- El archivo debe estar en UTF-8.
- Separador permitido: coma o punto y coma.
- Decimales permitidos: `9.99` o `9,99`.
- Filas invalidas se saltan y se registran en log local.
- Una fila invalida no debe romper todo el lote.
- `MaxRows` limita cuantas filas de datos se leen desde el CSV.
- `SendBatchSize` controla cuantos items se envian por request real.
- `StockPriceDryRunLimit` limita cuantos items se muestran en el payload de dry-run.
- `externalId`, `nombreOriginal`/`name`, `precioActual`/`price`, `stockUnidad` y `stockFraccion` son obligatorios.
- `precioActual`/`price` debe ser mayor o igual a cero.
- `stockUnidad` y `stockFraccion` deben ser mayores o iguales a cero.
- `puedeVender`/`canSell` default: `true`.
- `aplicaIvaOrigen`/`appliesIva` se preserva como texto de origen; si viene vacio se envia `null`.
- `ivaOrigenId`/`ivaId` se preserva como texto de origen.
- `precioOrigenTipo` puede ser `BASE` o `FINAL` si el origen lo conoce.
- `precioFinalCalculado` es solo auditoria si existe.
- El agente CSV no calcula IVA automaticamente.
- `estadoNombre`/`status` default: `ACTIVO`.
- `syncedAt` default: hora UTC de lectura si viene vacio.

## Payload catalog CSV

Endpoint:

```http
POST /api/integrations/neptuno/catalog
```

Payload:

```json
{
  "source": "neptuno",
  "agentId": "farmacia-principal-neptuno-001",
  "syncRunId": "opcional-20260622T022500Z",
  "items": [
    {
      "externalId": "NEP-000123",
      "nombreOriginal": "Producto ejemplo",
      "nombreLargo": "Producto ejemplo descripcion larga",
      "precioActual": 9.99,
      "stockUnidad": 12,
      "stockFraccion": 0,
      "bodegaExternalId": "1",
      "estadoExternalId": "ACT",
      "estadoNombre": "ACTIVO",
      "puedeVender": true,
      "aplicaIvaOrigen": "S",
      "ivaOrigenId": "0",
      "barcode": "7700000000012",
      "barcodeAlt": null,
      "categoriaExternalId": "CAT-1",
      "categoriaNombre": "Categoria origen",
      "subcategoriaExternalId": "SUB-1",
      "subcategoriaNombre": "Subcategoria origen",
      "presentacion": "TAB",
      "medida": "MG",
      "concentracion": "40",
      "unidadesPorCaja": 24,
      "generico": "N",
      "restriccionMedica": "N",
      "requiereMedico": false,
      "ventaSinStock": "N",
      "cronico": "N",
      "fabricanteExternalId": "FAB-1",
      "fabricanteCodigo": "LAB",
      "fabricanteNombre": "Laboratorio ejemplo",
      "vademecumExternalId": "VAD-1",
      "vademecumNombre": "Vademecum ejemplo",
      "syncedAt": "2026-06-22T02:24:30Z",
      "rawPayload": {
        "precioOriginal": "9.99",
        "aplicaIvaOrigen": "S",
        "ivaOrigenId": "0",
        "fechaIngreso": "2024-01-15",
        "tipoItem": "MED",
        "bodegaHabilitado": "S",
        "vademecumActivo": "S",
        "vademecumFabricanteId": "FAB-1",
        "ivaRateOrigen": "15",
        "sustitutoExternalId": "SUS-1",
        "sustitutoCodigo": "FURO",
        "sustitutoDescripcion": "FUROSEMIDA",
        "sustitutoNivel": "1",
        "sustitutoActivo": "S",
        "activeIngredientCandidate": "FUROSEMIDA",
        "activeIngredientCandidateSource": "in_item_sustituto",
        "proveedorPrincipalExternalId": "PROV-1",
        "proveedorPrincipalNombre": "Proveedor operativo",
        "proveedorPrincipalActivo": "S",
        "proveedorProductoDescripcion": "Producto proveedor",
        "proveedoresCount": "3",
        "proveedorSource": "in_proveedor_prod"
      }
    }
  ]
}
```

Reglas:

- El catalogo NEPTUNO alimenta `ExternalProduct` y revision admin.
- El catalogo no crea productos publicos automaticamente.
- El catalogo no activa productos, no indexa, no modifica sitemap y no toca checkout, carrito, PDP, `Product` publico ni motor de precios.
- `precioActual` sigue siendo dato operativo externo para `ExternalProduct` / `ProductLiveState`; no es precio publico automatico.
- `ProductLiveState.precioActual` no debe usarse automaticamente como precio de checkout publico sin capa de adaptacion.
- Cualquier paso futuro para crear un `Product` publico desde NEPTUNO necesita una capa de conversion editorial y comercial.
- `aplicaIvaOrigen` preserva valores de origen como `S`, `N`, `true`, `false` o `null`.
- `ivaOrigenId` preserva `in_item.id_iva` como string.
- `puedeVender` es boolean opcional.
- `requiereMedico` es boolean opcional.
- `generico`, `restriccionMedica`, `ventaSinStock` y `cronico` preservan texto de origen como `S`, `N` o `null`.
- `rawPayload` conserva solo valores permitidos para auditoria. No debe incluir costos, margenes, utilidad ni datos internos financieros.

## Formato CSV catalogo

Columnas recomendadas:

```csv
externalId,nombreOriginal,nombreLargo,precioActual,stockUnidad,stockFraccion,bodegaExternalId,estadoExternalId,estadoNombre,puedeVender,aplicaIvaOrigen,ivaOrigenId,barcode,barcodeAlt,categoriaExternalId,categoriaNombre,subcategoriaExternalId,subcategoriaNombre,presentacion,medida,concentracion,unidadesPorCaja,generico,restriccionMedica,requiereMedico,ventaSinStock,cronico,fabricanteExternalId,fabricanteCodigo,fabricanteNombre,vademecumExternalId,vademecumNombre,syncedAt
```

Alias amigables aceptados:

- `name` -> `nombreOriginal`
- `longName` -> `nombreLargo`
- `price` -> `precioActual`
- `warehouseExternalId` -> `bodegaExternalId`
- `status` -> `estadoNombre`
- `canSell` -> `puedeVender`
- `appliesIva` -> `aplicaIvaOrigen`
- `ivaId` -> `ivaOrigenId`
- `alternateBarcode` -> `barcodeAlt`

Reglas del lector:

- Archivo UTF-8.
- Separador permitido: coma o punto y coma.
- Decimales permitidos: `9.99` o `9,99`.
- Booleanos flexibles permitidos para `puedeVender` y `requiereMedico`: `S`, `N`, `true`, `false`, `1`, `0`, `si`, `no`.
- `generico`, `restriccionMedica`, `ventaSinStock` y `cronico` no se convierten a boolean; se preservan como texto de origen.
- Filas invalidas se saltan y se registran en log local.
- Una fila invalida no rompe todo el lote.
- `CatalogMaxRows` limita cuantas filas se leen.
- `CatalogSendBatchSize` controla cuantos items se envian por request real.
- `CatalogDryRunLimit` limita cuantos items se muestran en dry-run.
- Campos requeridos en CSV v1: `externalId`, `nombreOriginal`/`name`, `precioActual`/`price`, `stockUnidad`, `stockFraccion`.

## Catalog CSV v3 search candidates

CSV v3 conserva candidatos de busqueda y proveedor privado solo dentro de `rawPayload`. No agrega campos top-level al contrato, no cambia endpoint y no publica productos.

Campos de sustituto/principio activo candidato:

- `rawPayload.sustitutoExternalId`
- `rawPayload.sustitutoCodigo`
- `rawPayload.sustitutoDescripcion`
- `rawPayload.sustitutoNivel`
- `rawPayload.sustitutoActivo`
- `rawPayload.activeIngredientCandidate`
- `rawPayload.activeIngredientCandidateSource`

Reglas:

- `activeIngredientCandidateSource` debe ser trazable, por ejemplo `in_item_sustituto`.
- `sustitutoDescripcion` puede sugerir principio activo, grupo terapeutico o equivalencia NEPTUNO.
- No debe publicarse automaticamente como claim medico.
- No debe convertirse automaticamente en recomendacion medica.
- Debe pasar por selector/revision antes de entrar a `Product` publico.

Campos de proveedor privado:

- `rawPayload.proveedorPrincipalExternalId`
- `rawPayload.proveedorPrincipalNombre`
- `rawPayload.proveedorPrincipalActivo`
- `rawPayload.proveedorProductoDescripcion`
- `rawPayload.proveedoresCount`
- `rawPayload.proveedorSource`

Reglas:

- `proveedorSource` debe ser trazable, por ejemplo `in_proveedor_prod`.
- `proveedorPrincipal*` solo debe llenarse cuando NEPTUNO marca `in_proveedor_prod.principal = 'S'`.
- Si no existe proveedor con `principal = 'S'`, `proveedorPrincipalExternalId`, `proveedorPrincipalNombre`, `proveedorPrincipalActivo` y `proveedorProductoDescripcion` deben quedar vacios/null.
- `proveedoresCount` representa el total de relaciones proveedor-producto y debe mantenerse aunque no exista proveedor principal.
- No usar proveedor activo de fallback como proveedor principal.
- Si en una fase futura se conserva un fallback, debe tener otro nombre claro: `proveedorCandidatoNombre`, `proveedorFallbackNombre` o `proveedorSugeridoNombre`.
- No mostrar proveedor publicamente.
- Sirve para reposicion, trazabilidad y operacion.
- No enviarlo a SEO ni PDP publica por defecto.
- No usar proveedor como argumento comercial publico sin revision.

CTE recomendado para generar proveedor principal en CSV v3:

```sql
proveedor_principal AS (
  SELECT
    ipp.id_producto,
    ipp.id_proveedor,
    ipp.descripcion AS proveedorProductoDescripcion,
    ipp.principal,
    pp.activo AS proveedorActivo,
    ce.nombre_completo AS proveedorNombre,
    ROW_NUMBER() OVER (
      PARTITION BY ipp.id_producto
      ORDER BY ipp.id_proveedor
    ) AS rn
  FROM in_proveedor_prod ipp
  LEFT JOIN pr_proveedor pp
    ON pp.id_proveedor = ipp.id_proveedor
  LEFT JOIN co_ente ce
    ON ce.id_ente = ipp.id_proveedor
  WHERE ipp.principal = 'S'
)
```

Sintomas:

- NEPTUNO no tiene sintomas poblados en `fa_sintoma`.
- NEPTUNO no tiene una relacion producto -> sintoma util confirmada.
- Sintomas e intenciones de busqueda deben ser editoriales en Vidalinkco y manejarse por selector normalizado.

## Mapeo NEPTUNO a catalogo Vidalinkco

- `in_item.id_item` -> `externalId`
- `in_item.descripcion` -> `nombreOriginal`
- `in_item.descripcion_larga` -> `nombreLargo`
- `in_item.precio` -> `precioActual` operativo externo
- `in_item.aplica_iva` -> `aplicaIvaOrigen`
- `in_item.id_iva` -> `ivaOrigenId`
- `in_item.cod_barra` -> `barcode`
- `in_item.cod_barra_alterno` -> `barcodeAlt`
- `in_item.id_clasif_1` -> `categoriaExternalId`
- `in_item.id_clasif_2` -> `subcategoriaExternalId`
- `in_item.id_estado_item` -> `estadoExternalId`
- `in_item.fecha_ingreso` -> `rawPayload.fechaIngreso`
- `in_item.tipo_item` -> `rawPayload.tipoItem`
- `in_item.id_marca_item` -> `rawPayload.marcaItemExternalId`
- `in_item_bodega.id_bodega` -> `bodegaExternalId`
- `in_item_bodega.stock_unidad` -> `stockUnidad`
- `in_item_bodega.stock_fraccion` -> `stockFraccion`
- `in_item_bodega.habilitado` -> `rawPayload.bodegaHabilitado`
- `in_item_bodega.id_ubicacion` -> `rawPayload.ubicacion`
- `in_item_bodega.fecha_ult_venta` -> `rawPayload.fechaUltVenta`
- `in_item_bodega.fecha_ult_compra` -> `rawPayload.fechaUltCompra`
- `in_item_bodega.fecha_ult_trans` -> `rawPayload.fechaUltTrans`
- `in_item_bodega.fecha_ult_ajuste` -> `rawPayload.fechaUltAjuste`
- `in_estado_item.descripcion` -> `estadoNombre`
- `in_estado_item.puede_vender` -> `puedeVender`
- `in_estado_item.codigo` -> `rawPayload.estadoCodigo`
- `in_estado_item.activo` -> `rawPayload.estadoActivo`
- `in_nodo_clasif_1.descripcion` -> `categoriaNombre`
- `in_nodo_clasif_2.descripcion` -> `subcategoriaNombre`
- `in_producto.presentacion` -> `presentacion`
- `in_producto.medida` -> `medida`
- `in_producto.concentracion` -> `concentracion`
- `in_producto.num_fraccion` -> `unidadesPorCaja`
- `in_producto.generico` -> `generico`
- `in_producto.restric_medica` -> `restriccionMedica`
- `in_producto.requiere_medico` -> `requiereMedico`
- `in_producto.venta_sin_stock` -> `ventaSinStock`
- `in_producto.cronico` -> `cronico`
- `in_producto.id_fabricante` -> `fabricanteExternalId`
- `in_fabricante.mnemonico` -> `fabricanteCodigo`
- `co_ente.nombre_completo` -> `fabricanteNombre`
- `in_producto.id_vademecum` -> `vademecumExternalId`
- `fa_vademecum.descripcion` -> `vademecumNombre`
- `fa_vademecum.activo` -> `rawPayload.vademecumActivo`
- `fa_vademecum.id_fabricante` -> `rawPayload.vademecumFabricanteId`
- `im_impuesto_iva.porcentaje` -> `rawPayload.ivaRateOrigen`
- `in_item_sustituto` -> `rawPayload.sustitutoExternalId`, `rawPayload.sustitutoNivel`
- `in_sustituto` -> `rawPayload.sustitutoCodigo`, `rawPayload.sustitutoDescripcion`, `rawPayload.sustitutoActivo`, `rawPayload.activeIngredientCandidate`
- `in_proveedor_prod` con `principal = 'S'` -> `rawPayload.proveedorPrincipalExternalId`, `rawPayload.proveedorProductoDescripcion`, `rawPayload.proveedorPrincipalNombre`, `rawPayload.proveedorPrincipalActivo`
- `in_proveedor_prod` total por producto -> `rawPayload.proveedoresCount`, `rawPayload.proveedorSource`

## Campos excluidos de catalogo v1

No incluir en payload ni en `rawPayload`:

- `costo_prom_0`
- `costo_prom_1`
- `costo_ult_compra`
- `costo_servicio`
- `porc_utilidad`
- `vvf`
- `pvf`
- `precio_ant`
- cualquier margen, utilidad, costo de compra o dato interno financiero

Razon: son datos internos sensibles, no son necesarios para publicacion editorial y no deben viajar al VPS en esta fase.

## Vademecum v1

En esta fase solo se envia metadata:

- `vademecumExternalId`
- `vademecumNombre`
- `rawPayload.vademecumActivo`
- `rawPayload.vademecumFabricanteId`

No enviar todavia `fa_vademecum.cabecera`. No enviar blobs, imagenes ni textos medicos largos. El vademecum completo sera una fase separada.

## Seguridad

- La API key real nunca se versiona.
- `appsettings.local.json` queda ignorado por git.
- No se registran claves ni connection strings en logs.
- Solo se permite `https` para `VidalinkcoBaseUrl`.
- El agente usa `source = neptuno` como identificador obligatorio.
- Dry-run no envia requests HTTP.
- Los errores deben registrar codigo/causa sin exponer secretos.

## Batch size

Valor inicial:

- Heartbeat: `BatchSize = 100`
- Stock/precio CSV: `SendBatchSize = 100`
- Catalogo CSV: `CatalogSendBatchSize = 100`

Limites del agente:

- Minimo: `1`
- Maximo: `500`

El backend debe validar tambien el limite y rechazar lotes demasiado grandes con envelope:

```json
{ "ok": false, "error": "batch_too_large" }
```

## Reintentos

Regla inicial:

- Heartbeat en modo worker: reintenta en el siguiente intervalo configurado.
- Timeouts HTTP: 30 segundos.
- Stock/precio CSV manual: si un batch falla, el comando registra status/body resumido y termina con error.
- Catalogo CSV manual: si un batch falla, el comando registra status/body resumido y termina con error.
- Futuro SQL/catalog: usar lotes idempotentes por `batchId` o cursor confirmado.
- Futuro SQL/catalog: reintentar errores transitorios HTTP `408`, `429`, `500`, `502`, `503`, `504`.
- No reintentar indefinidamente errores de contrato `400`, `401`, `403`, `422`; deben quedar visibles en logs.

## PC apagada u offline

Comportamiento inicial:

- Si la PC esta apagada, no se genera heartbeat ni sincronizacion.
- Al iniciar de nuevo, el agente enviara heartbeat en la siguiente ejecucion.
- Futuro stock/catalog debe calcular cambios pendientes desde la ultima marca confirmada por Vidalinkco o desde un cursor local persistido.
- No se debe marcar stock como cero por ausencia de heartbeat.
- La ausencia de heartbeat debe interpretarse como agente offline, no como farmacia sin inventario.

## Tablas NEPTUNO a evaluar despues

Los nombres exactos deben confirmarse contra la instalacion real de NEPTUNO antes de implementar SQL Server. Candidatas a auditar:

- Productos/articulos: catalogo base, codigos internos, codigos de barra, descripcion, estado.
- Existencias/inventario: stock disponible por bodega o punto de venta.
- Precios: precio de venta vigente, listas de precios, moneda.
- Laboratorios/marcas: datos de fabricante o marca si existen.
- Categorias/grupos: clasificacion comercial si existe.
- Kardex/movimientos: fuente futura para sincronizacion incremental si NEPTUNO la expone.

No se debe asumir estructura final hasta revisar schema real, permisos y volumen de datos.
