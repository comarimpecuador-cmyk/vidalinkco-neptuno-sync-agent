# NEPTUNO Sync Agent Contract

## Proposito

El agente Vidalinkco NEPTUNO Sync Agent corre en una PC Windows de farmacia para preparar la sincronizacion segura entre NEPTUNO SQL Server y Vidalinkco por HTTPS.

En esta fase el agente solo implementa configuracion segura, heartbeat, dry-run y contratos documentados. No conecta todavia a SQL Server, no instala Windows Service y no envia stock, precios ni catalogo.

## Endpoints Vidalinkco

Base URL configurable por ambiente:

- `NeptunoSyncAgent:VidalinkcoBaseUrl`

Header obligatorio para endpoints de integracion:

- `x-vidalinkco-integration-key: <api-key-local>`

Endpoints:

- `POST /api/integrations/neptuno/heartbeat`
- Futuro: `POST /api/integrations/neptuno/stock-price`
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

## Payload stock-price futuro

Endpoint futuro:

```http
POST /api/integrations/neptuno/stock-price
```

Payload futuro propuesto:

```json
{
  "agentId": "farmacia-principal-neptuno-001",
  "source": "neptuno",
  "occurredAtUtc": "2026-06-22T02:20:00Z",
  "batchId": "20260622T022000Z-0001",
  "items": [
    {
      "externalProductId": "NEP-000123",
      "sku": "7700000000012",
      "barcode": "7700000000012",
      "name": "Producto ejemplo",
      "stock": 12,
      "price": 9.99,
      "currency": "USD",
      "updatedAtUtc": "2026-06-22T02:19:30Z"
    }
  ]
}
```

Reglas:

- `externalProductId` debe ser estable desde NEPTUNO.
- `stock` no puede ser negativo.
- `price` debe ser mayor o igual a cero.
- `items.length` no debe superar `BatchSize`.
- El backend debe tratar `batchId` como idempotente.

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

- `BatchSize = 100`

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
- Futuro stock/catalog: usar lotes idempotentes por `batchId`.
- Futuro stock/catalog: reintentar errores transitorios HTTP `408`, `429`, `500`, `502`, `503`, `504`.
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
