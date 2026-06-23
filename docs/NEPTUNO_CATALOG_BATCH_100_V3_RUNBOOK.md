# NEPTUNO catalog batch 100 v3 runbook

## Objetivo

Preparar un lote controlado de 100 productos reales de NEPTUNO para validar el CSV de catalogo v3 desde la PC de farmacia. Esta fase no envia datos por defecto, no cambia el contrato y no modifica Vidalinkco web.

## Contrato CSV v3 vigente

El contrato vigente se deriva de:

- `Vidalinkco.NeptunoSyncAgent/Infrastructure/CatalogCsvReader.cs`
- `Vidalinkco.NeptunoSyncAgent/Contracts/CatalogContracts.cs`
- `docs/NEPTUNO_SYNC_AGENT_CONTRACT.md`
- `docs/NEPTUNO_SEARCH_DISCOVERY_SSOT.md`
- `docs/VIDALINKCO_FIELD_GAP_ANALYSIS.md`

Columnas top-level del catalogo:

```text
externalId,nombreOriginal,nombreLargo,precioActual,stockUnidad,stockFraccion,bodegaExternalId,estadoExternalId,estadoNombre,puedeVender,aplicaIvaOrigen,ivaOrigenId,barcode,barcodeAlt,categoriaExternalId,categoriaNombre,subcategoriaExternalId,subcategoriaNombre,presentacion,medida,concentracion,unidadesPorCaja,generico,restriccionMedica,requiereMedico,ventaSinStock,cronico,fabricanteExternalId,fabricanteCodigo,fabricanteNombre,vademecumExternalId,vademecumNombre,syncedAt
```

Columnas adicionales que el lector conserva dentro de `rawPayload` para CSV v3:

```text
precioOrigenTipo,precioFinalCalculado,fechaIngreso,tipoItem,marcaItemExternalId,bodegaHabilitado,ubicacion,fechaUltVenta,fechaUltCompra,fechaUltTrans,fechaUltAjuste,estadoCodigo,estadoActivo,vademecumActivo,vademecumFabricanteId,ivaRateOrigen,sustitutoExternalId,sustitutoCodigo,sustitutoDescripcion,sustitutoNivel,sustitutoActivo,activeIngredientCandidate,activeIngredientCandidateSource,proveedorPrincipalExternalId,proveedorPrincipalNombre,proveedorPrincipalActivo,proveedorProductoDescripcion,proveedoresCount,proveedorSource
```

No cambiar nombres de columnas, payload ni parsing para este lote.

## SQL de referencia

Usar el SQL documental:

```text
docs/sql/catalog-real-batch-100-v3.sql
```

El SQL selecciona 100 filas y prioriza productos con stock o movimiento reciente desde fuentes ya validadas. No usa tablas de ventas corruptas ni tablas dependientes de paginas con checksum danado.

Fuentes usadas:

- `in_item`
- `in_producto`
- `in_item_bodega`
- `in_estado_item`
- `in_nodo_clasif_1`
- `in_nodo_clasif_2`
- `in_fabricante`
- `co_ente`
- `fa_vademecum`
- `im_impuesto_iva`
- `in_item_sustituto`
- `in_sustituto`
- `in_proveedor_prod`
- `pr_proveedor`

Reglas del SQL:

- No exporta costos, margenes, utilidad, compras, PVF/VVF ni informacion financiera sensible.
- No exporta blobs de vademecum.
- `proveedorPrincipal*` solo se llena cuando `in_proveedor_prod.principal = 'S'`.
- Si no hay proveedor principal, `proveedorPrincipalExternalId`, `proveedorPrincipalNombre`, `proveedorPrincipalActivo` y `proveedorProductoDescripcion` salen `NULL`.
- `proveedoresCount` conserva el conteo total de relaciones proveedor-producto aunque no exista proveedor principal.
- `activeIngredientCandidate` sale desde `sustitutoDescripcion`.
- `activeIngredientCandidateSource` conserva `in_item_sustituto`.
- `proveedorSource` conserva `in_proveedor_prod` cuando hay relaciones proveedor-producto.

## Generar CSV en la PC de farmacia

1. Abrir el SQL en la herramienta local de NEPTUNO/SQL Server.
2. Ejecutarlo contra la base NEPTUNO real.
3. Exportar el resultado como CSV UTF-8 con encabezados.
4. Guardarlo localmente como:

```text
catalog-real-batch-100-v3.csv
```

5. Copiar el archivo al repo del agente:

```text
samples/catalog-real-batch-100-v3.csv
```

No versionar este CSV. Debe seguir ignorado por Git.

## Configuracion local recomendada

Editar solo `Vidalinkco.NeptunoSyncAgent/appsettings.local.json` en la PC local. No versionar ese archivo.

Ejemplo:

```json
{
  "NeptunoSyncAgent": {
    "CatalogCsvPath": "../samples/catalog-real-batch-100-v3.csv",
    "CatalogMaxRows": 100,
    "CatalogSendBatchSize": 50,
    "CatalogDryRunLimit": 5,
    "DryRun": true
  }
}
```

Para envio real, cambiar temporalmente:

```json
{
  "NeptunoSyncAgent": {
    "DryRun": false,
    "ApiKey": "API_KEY_LOCAL_NO_VERSIONADA"
  }
}
```

Despues del envio real, volver a:

```json
{
  "NeptunoSyncAgent": {
    "DryRun": true
  }
}
```

## Dry-run obligatorio

Ejecutar primero:

```powershell
dotnet run --project .\Vidalinkco.NeptunoSyncAgent -- --catalog-csv-once --dry-run
```

Revisar en salida/logs:

```text
TotalRead=100
TotalValid=100
TotalInvalid=0
```

Si `TotalInvalid > 0`, no enviar. Revisar las filas invalidas y regenerar el CSV.

## Envio real controlado

Solo despues de dry-run correcto y con API key local configurada:

```powershell
dotnet run --project .\Vidalinkco.NeptunoSyncAgent -- --catalog-csv-once
```

Con `CatalogSendBatchSize = 50`, el lote de 100 productos se envia en 2 requests. No pegar API keys ni payloads reales en tickets, chats o commits.

Despues del envio, volver `DryRun` a `true`.

## Verificacion Git antes y despues

```powershell
git status --short --untracked-files=all
git ls-files "*.csv" "*.tsv"
git check-ignore -v .\samples\catalog-real-batch-100-v3.csv
git check-ignore -v .\Vidalinkco.NeptunoSyncAgent\appsettings.local.json
git diff --check
```

Resultados esperados:

- `samples/catalog-real-batch-100-v3.csv` aparece ignorado por `.gitignore`.
- `Vidalinkco.NeptunoSyncAgent/appsettings.local.json` aparece ignorado por `.gitignore`.
- `git ls-files "*.csv" "*.tsv"` no lista CSV/TSV reales versionados.
- `git diff --check` no muestra errores.

## Seguridad

- Esta fase no toca `vidalinkco-web`.
- No cambia endpoints de Vidalinkco.
- No cambia contrato CSV v3.
- No cambia parsing.
- No envia datos por defecto.
- No versiona CSV reales.
- No versiona secretos.
- No cambia `appsettings.local.json`.
- No publica productos, no toca PDP publica, SEO, sitemap, robots, checkout ni `Product` publico.
