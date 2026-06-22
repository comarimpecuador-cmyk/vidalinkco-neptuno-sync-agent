# Vidalinkco NEPTUNO Sync Agent

Agente Windows para preparar la sincronizacion entre NEPTUNO y Vidalinkco por HTTPS. En esta fase no conecta a SQL Server ni instala Windows Service; permite probar heartbeat y envio de stock/precio desde CSV local con ejecucion manual por consola.

## Configuracion

1. Copia `Vidalinkco.NeptunoSyncAgent/appsettings.example.json` como `Vidalinkco.NeptunoSyncAgent/appsettings.local.json`.
2. Edita `appsettings.local.json` localmente.
3. Define `NeptunoSyncAgent:ApiKey` solo en `appsettings.local.json` o variables de entorno. Nunca subas la API key al repositorio.
4. Manten `DryRun: true` hasta validar el payload.

`appsettings.local.json` esta ignorado por git.

## Ejecutar heartbeat en dry-run

Desde la raiz del repositorio:

```powershell
dotnet run --project .\Vidalinkco.NeptunoSyncAgent -- --heartbeat-once --dry-run
```

Esto imprime el payload y escribe un registro local en `logs/agent.log`. No envia datos a Vidalinkco.

## Ejecutar heartbeat real

Configura `appsettings.local.json` con:

```json
{
  "NeptunoSyncAgent": {
    "VidalinkcoBaseUrl": "https://tu-dominio-vidalinkco.com",
    "ApiKey": "valor-real-solo-local",
    "DryRun": false
  }
}
```

Luego ejecuta:

```powershell
dotnet run --project .\Vidalinkco.NeptunoSyncAgent -- --heartbeat-once
```

El cliente enviara `POST /api/integrations/neptuno/heartbeat` con el header `x-vidalinkco-integration-key`. No imprimas ni pegues la API key en logs, issues o commits.

## CSV stock/precio

El envio CSV usa `NeptunoSyncAgent:StockPriceCsvPath`. Los CSV reales de NEPTUNO no se versionan; `*.csv` y `*.tsv` estan ignorados por git.

Columnas recomendadas, alineadas al contrato Vidalinkco:

```csv
externalId,nombreOriginal,precioActual,stockUnidad,stockFraccion,bodegaExternalId,estadoExternalId,estadoNombre,puedeVender,aplicaIvaOrigen,ivaOrigenId,precioOrigenTipo,precioFinalCalculado,barcode,barcodeAlt,syncedAt
```

Por compatibilidad operativa, el CSV tambien puede usar alias amigables anteriores: `name`, `price`, `warehouseExternalId`, `status`, `canSell`, `appliesIva`, `ivaId` y `alternateBarcode`. El payload enviado a Vidalinkco siempre usa los nombres reales del backend: `nombreOriginal`, `precioActual`, `bodegaExternalId`, `estadoNombre`, `puedeVender`, `aplicaIvaOrigen`, `ivaOrigenId` y `barcodeAlt`.

Reglas del lector:

- Archivo en UTF-8.
- Separador coma o punto y coma.
- Decimales con punto o coma.
- `externalId`, `nombreOriginal`/`name`, `precioActual`/`price`, `stockUnidad` y `stockFraccion` son obligatorios.
- `precioActual`/`price`, `stockUnidad` y `stockFraccion` no pueden ser negativos.
- `puedeVender`/`canSell` acepta `true/false`, `1/0`, `yes/no`, `si/no`; default `true`.
- `aplicaIvaOrigen`/`appliesIva` se preserva como texto de origen, por ejemplo `S`, `N`, `true`, `false`, `1`, `0` o `null` si viene vacio.
- `ivaOrigenId`/`ivaId` preserva el `id_iva` de origen como texto.
- `precioOrigenTipo` puede indicar `BASE` o `FINAL` si se conoce.
- `precioFinalCalculado` es solo auditoria si existe; el agente CSV no calcula IVA automaticamente.
- `rawPayload` no se lee como columna; el agente lo genera con los valores originales del CSV para auditoria.
- `syncedAt` es opcional; si falta, el agente usa la hora UTC de lectura.
- Filas invalidas se saltan y quedan registradas en logs.

`precioActual` es un precio operativo para monitoreo externo en `ExternalProduct` / `ProductLiveState`. No publica, no indexa y no modifica `Product`. `ProductLiveState.precioActual` no debe usarse automaticamente como precio de checkout publico sin una capa de adaptacion que respete la logica actual de `Product.precio` + `Product.iva` en Vidalinkco.

## Ejecutar stock/precio CSV en dry-run

Configura `StockPriceCsvPath` en `appsettings.local.json` apuntando a un CSV local. Luego:

```powershell
dotnet run --project .\Vidalinkco.NeptunoSyncAgent -- --stock-price-csv-once --dry-run
```

El dry-run muestra total leido, total valido, total invalido y el primer payload/batch sin enviar datos.

## Ejecutar stock/precio CSV real

Con `DryRun: false`, `VidalinkcoBaseUrl` real, `ApiKey` real solo local y `StockPriceCsvPath` local:

```powershell
dotnet run --project .\Vidalinkco.NeptunoSyncAgent -- --stock-price-csv-once
```

El agente envia `POST /api/integrations/neptuno/stock-price` por lotes de `SendBatchSize`. No pegues la API key ni CSV reales en commits, issues o logs compartidos.

## Publicar EXE self-contained para Windows

```powershell
dotnet publish .\Vidalinkco.NeptunoSyncAgent -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o .\publish\win-x64
```

Despues de publicar, coloca un `appsettings.local.json` junto al ejecutable si necesitas configuracion real local.

## Estado de esta fase

- Implementado: configuracion tipada, dry-run, cliente HTTPS, heartbeat manual, CSV stock/precio manual, ciclo worker de heartbeat y logging local basico.
- No implementado todavia: conexion SQL Server real, lectura de tablas NEPTUNO, catalogo y Windows Service.
