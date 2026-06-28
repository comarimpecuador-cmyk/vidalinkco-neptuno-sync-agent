/*
  NEPTUNO Phase 9A-1B live price/stock query.
  Runtime parameters: @BodegaId (bigint), @MaxProducts (int) and optional
  parameterized @ExternalIdN values injected at the marked filter placeholder.
  Read-only operational data only.
*/

SELECT TOP (@MaxProducts)
    CAST(i.id_item AS varchar(50)) AS externalId,
    CAST(ib.id_bodega AS varchar(50)) AS bodegaExternalId,
    CAST(b.nombre AS varchar(250)) AS bodegaNombre,
    CAST(i.precio AS decimal(18, 4)) AS precioActual,
    CAST(ISNULL(ib.stock_unidad, 0) AS decimal(18, 4)) AS stockUnidad,
    CAST(ISNULL(ib.stock_fraccion, 0) AS decimal(18, 4)) AS stockFraccion,
    CAST(i.id_estado_item AS varchar(50)) AS estadoExternalId,
    CAST(ei.descripcion AS varchar(120)) AS estadoNombre,
    CAST(ei.puede_vender AS varchar(10)) AS puedeVender,
    CAST(i.aplica_iva AS varchar(10)) AS aplicaIvaOrigen,
    CAST(i.id_iva AS varchar(50)) AS ivaOrigenId,
    CAST(ib.habilitado AS varchar(10)) AS bodegaHabilitado
FROM in_item AS i
INNER JOIN in_item_bodega AS ib
    ON ib.id_item = i.id_item
   AND ib.id_bodega = @BodegaId
LEFT JOIN in_bodega AS b
    ON b.id_bodega = ib.id_bodega
LEFT JOIN in_estado_item AS ei
    ON ei.id_estado_item = i.id_estado_item
WHERE i.id_item IS NOT NULL
  AND i.precio IS NOT NULL
/*__EXTERNAL_IDS_FILTER__*/
ORDER BY i.id_item;
