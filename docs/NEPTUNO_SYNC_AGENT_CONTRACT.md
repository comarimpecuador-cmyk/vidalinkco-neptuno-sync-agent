# NEPTUNO Sync Agent Contract

## Proposito

El agente Vidalinkco NEPTUNO Sync Agent corre en una PC Windows de farmacia para preparar la sincronizacion segura entre NEPTUNO SQL Server y Vidalinkco por HTTPS.

En esta fase el agente implementa configuracion segura, heartbeat, dry-run y envio manual de stock/precio desde CSV local. No conecta todavia a SQL Server, no instala Windows Service y no envia catalogo.

## Endpoints Vidalinkco

Base URL configurable por ambiente:

- `NeptunoSyncAgent:VidalinkcoBaseUrl`

Header obligatorio para endpoints de integracion:

- `x-vidalinkco-integration-key: <api-key-local>`

Endpoints:

- `POST /api/integrations/neptuno/heartbeat`
- `POST /api/integrations/neptuno/stock-price`
- Futuro: `POST /api/integrations/neptuno/catalog`

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

## Payload catalog futuro

Endpoint futuro:

```http
POST /api/integrations/neptuno/catalog
```

Payload futuro propuesto:

```json
{
  "agentId": "farmacia-principal-neptuno-001",
  "source": "neptuno",
  "occurredAtUtc": "2026-06-22T02:25:00Z",
  "batchId": "20260622T022500Z-0001",
  "items": [
    {
      "externalProductId": "NEP-000123",
      "sku": "7700000000012",
      "barcode": "7700000000012",
      "name": "Producto ejemplo",
      "description": "Descripcion proveniente de NEPTUNO si existe",
      "brand": "Marca ejemplo",
      "category": "Categoria ejemplo",
      "isActive": true,
      "updatedAtUtc": "2026-06-22T02:24:30Z"
    }
  ]
}
```

Reglas:

- El catalogo no debe borrar productos en Vidalinkco de forma implicita.
- `isActive: false` debe interpretarse como desactivacion controlada, no eliminacion fisica.
- Campos editoriales de Vidalinkco deben seguir siendo propiedad del backend Vidalinkco salvo contrato explicito posterior.

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
