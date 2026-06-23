/*
  NEPTUNO catalog CSV v3 - lote real 100

  Uso:
  - Ejecutar en la PC de farmacia contra la base NEPTUNO real.
  - Exportar resultado como CSV UTF-8 con encabezados.
  - Guardar como samples/catalog-real-batch-100-v3.csv.

  Seguridad:
  - No exporta costos, margenes, utilidad, compras, PVF/VVF ni datos financieros sensibles.
  - No exporta blobs ni textos largos de vademecum.
  - Mantiene proveedor principal solo cuando in_proveedor_prod.principal = 'S'.
  - Si no hay proveedor principal, proveedorPrincipal* sale NULL.
*/

WITH bodega_preferida AS (
  SELECT
    ib.id_item,
    ib.id_bodega,
    ib.stock_unidad,
    ib.stock_fraccion,
    ib.habilitado,
    ib.id_ubicacion,
    ib.fecha_ult_venta,
    ib.fecha_ult_compra,
    ib.fecha_ult_trans,
    ib.fecha_ult_ajuste,
    ROW_NUMBER() OVER (
      PARTITION BY ib.id_item
      ORDER BY
        CASE
          WHEN ISNULL(ib.stock_unidad, 0) > 0 OR ISNULL(ib.stock_fraccion, 0) > 0 THEN 0
          ELSE 1
        END,
        (
          SELECT MAX(v)
          FROM (VALUES
            (ib.fecha_ult_venta),
            (ib.fecha_ult_compra),
            (ib.fecha_ult_trans),
            (ib.fecha_ult_ajuste)
          ) AS fechas(v)
        ) DESC,
        ib.id_bodega
    ) AS rn
  FROM in_item_bodega ib
),
sustituto_candidato AS (
  SELECT
    iis.id_item,
    iis.id_sustituto,
    iis.nivel AS sustitutoNivel,
    s.codigo AS sustitutoCodigo,
    s.descripcion AS sustitutoDescripcion,
    s.activo AS sustitutoActivo,
    ROW_NUMBER() OVER (
      PARTITION BY iis.id_item
      ORDER BY
        CASE WHEN s.activo = 'S' THEN 0 ELSE 1 END,
        ISNULL(iis.nivel, 999999),
        iis.id_sustituto
    ) AS rn
  FROM in_item_sustituto iis
  LEFT JOIN in_sustituto s
    ON s.id_sustituto = iis.id_sustituto
),
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
),
proveedor_count AS (
  SELECT
    ipp.id_producto,
    COUNT(*) AS proveedoresCount
  FROM in_proveedor_prod ipp
  GROUP BY ipp.id_producto
),
catalogo_base AS (
  SELECT
    i.id_item,
    i.id_producto,
    bp.id_bodega,
    bp.stock_unidad,
    bp.stock_fraccion,
    bp.habilitado AS bodegaHabilitado,
    bp.id_ubicacion,
    bp.fecha_ult_venta,
    bp.fecha_ult_compra,
    bp.fecha_ult_trans,
    bp.fecha_ult_ajuste,
    ROW_NUMBER() OVER (
      ORDER BY
        CASE
          WHEN ISNULL(bp.stock_unidad, 0) > 0 OR ISNULL(bp.stock_fraccion, 0) > 0 THEN 0
          ELSE 1
        END,
        (
          SELECT MAX(v)
          FROM (VALUES
            (bp.fecha_ult_venta),
            (bp.fecha_ult_compra),
            (bp.fecha_ult_trans),
            (bp.fecha_ult_ajuste),
            (i.fecha_ingreso)
          ) AS fechas(v)
        ) DESC,
        i.id_item
    ) AS rn_global
  FROM in_item i
  LEFT JOIN bodega_preferida bp
    ON bp.id_item = i.id_item
   AND bp.rn = 1
  WHERE
    i.id_item IS NOT NULL
    AND i.descripcion IS NOT NULL
    AND i.precio IS NOT NULL
)
SELECT TOP (100)
  CAST(i.id_item AS varchar(50)) AS externalId,
  CAST(i.descripcion AS varchar(250)) AS nombreOriginal,
  CAST(i.descripcion_larga AS varchar(500)) AS nombreLargo,
  CAST(i.precio AS decimal(18, 4)) AS precioActual,
  CAST(ISNULL(cb.stock_unidad, 0) AS decimal(18, 4)) AS stockUnidad,
  CAST(ISNULL(cb.stock_fraccion, 0) AS decimal(18, 4)) AS stockFraccion,
  CAST(cb.id_bodega AS varchar(50)) AS bodegaExternalId,
  CAST(i.id_estado_item AS varchar(50)) AS estadoExternalId,
  CAST(ei.descripcion AS varchar(120)) AS estadoNombre,
  CAST(ei.puede_vender AS varchar(10)) AS puedeVender,
  CAST(i.aplica_iva AS varchar(10)) AS aplicaIvaOrigen,
  CAST(i.id_iva AS varchar(50)) AS ivaOrigenId,
  CAST(i.cod_barra AS varchar(80)) AS barcode,
  CAST(i.cod_barra_alterno AS varchar(80)) AS barcodeAlt,
  CAST(i.id_clasif_1 AS varchar(50)) AS categoriaExternalId,
  CAST(c1.descripcion AS varchar(180)) AS categoriaNombre,
  CAST(i.id_clasif_2 AS varchar(50)) AS subcategoriaExternalId,
  CAST(c2.descripcion AS varchar(180)) AS subcategoriaNombre,
  CAST(p.presentacion AS varchar(120)) AS presentacion,
  CAST(p.medida AS varchar(120)) AS medida,
  CAST(p.concentracion AS varchar(120)) AS concentracion,
  CAST(p.num_fraccion AS decimal(18, 4)) AS unidadesPorCaja,
  CAST(p.generico AS varchar(10)) AS generico,
  CAST(p.restric_medica AS varchar(50)) AS restriccionMedica,
  CAST(p.requiere_medico AS varchar(10)) AS requiereMedico,
  CAST(p.venta_sin_stock AS varchar(10)) AS ventaSinStock,
  CAST(p.cronico AS varchar(10)) AS cronico,
  CAST(p.id_fabricante AS varchar(50)) AS fabricanteExternalId,
  CAST(f.mnemonico AS varchar(80)) AS fabricanteCodigo,
  CAST(fabricante_ente.nombre_completo AS varchar(250)) AS fabricanteNombre,
  CAST(p.id_vademecum AS varchar(50)) AS vademecumExternalId,
  CAST(v.descripcion AS varchar(250)) AS vademecumNombre,
  CONVERT(varchar(33), SYSDATETIMEOFFSET(), 127) AS syncedAt,
  CAST('BASE' AS varchar(20)) AS precioOrigenTipo,
  CAST(NULL AS decimal(18, 4)) AS precioFinalCalculado,
  CONVERT(varchar(33), i.fecha_ingreso, 126) AS fechaIngreso,
  CAST(i.tipo_item AS varchar(50)) AS tipoItem,
  CAST(i.id_marca_item AS varchar(50)) AS marcaItemExternalId,
  CAST(cb.bodegaHabilitado AS varchar(10)) AS bodegaHabilitado,
  CAST(cb.id_ubicacion AS varchar(50)) AS ubicacion,
  CONVERT(varchar(33), cb.fecha_ult_venta, 126) AS fechaUltVenta,
  CONVERT(varchar(33), cb.fecha_ult_compra, 126) AS fechaUltCompra,
  CONVERT(varchar(33), cb.fecha_ult_trans, 126) AS fechaUltTrans,
  CONVERT(varchar(33), cb.fecha_ult_ajuste, 126) AS fechaUltAjuste,
  CAST(ei.codigo AS varchar(50)) AS estadoCodigo,
  CAST(ei.activo AS varchar(10)) AS estadoActivo,
  CAST(v.activo AS varchar(10)) AS vademecumActivo,
  CAST(v.id_fabricante AS varchar(50)) AS vademecumFabricanteId,
  CAST(iva.porcentaje AS varchar(30)) AS ivaRateOrigen,
  CAST(sc.id_sustituto AS varchar(50)) AS sustitutoExternalId,
  CAST(sc.sustitutoCodigo AS varchar(120)) AS sustitutoCodigo,
  CAST(sc.sustitutoDescripcion AS varchar(250)) AS sustitutoDescripcion,
  CAST(sc.sustitutoNivel AS varchar(50)) AS sustitutoNivel,
  CAST(sc.sustitutoActivo AS varchar(10)) AS sustitutoActivo,
  CAST(sc.sustitutoDescripcion AS varchar(250)) AS activeIngredientCandidate,
  CAST(CASE WHEN sc.id_sustituto IS NULL THEN NULL ELSE 'in_item_sustituto' END AS varchar(80)) AS activeIngredientCandidateSource,
  CAST(pp.id_proveedor AS varchar(50)) AS proveedorPrincipalExternalId,
  CAST(pp.proveedorNombre AS varchar(250)) AS proveedorPrincipalNombre,
  CAST(pp.proveedorActivo AS varchar(10)) AS proveedorPrincipalActivo,
  CAST(pp.proveedorProductoDescripcion AS varchar(250)) AS proveedorProductoDescripcion,
  CAST(ISNULL(pc.proveedoresCount, 0) AS varchar(20)) AS proveedoresCount,
  CAST(CASE WHEN pc.proveedoresCount IS NULL THEN NULL ELSE 'in_proveedor_prod' END AS varchar(80)) AS proveedorSource
FROM catalogo_base cb
JOIN in_item i
  ON i.id_item = cb.id_item
LEFT JOIN in_producto p
  ON p.id_producto = i.id_producto
LEFT JOIN in_estado_item ei
  ON ei.id_estado_item = i.id_estado_item
LEFT JOIN in_nodo_clasif_1 c1
  ON c1.id_clasif_1 = i.id_clasif_1
LEFT JOIN in_nodo_clasif_2 c2
  ON c2.id_clasif_2 = i.id_clasif_2
LEFT JOIN in_fabricante f
  ON f.id_fabricante = p.id_fabricante
LEFT JOIN co_ente fabricante_ente
  ON fabricante_ente.id_ente = f.id_ente
LEFT JOIN fa_vademecum v
  ON v.id_vademecum = p.id_vademecum
LEFT JOIN im_impuesto_iva iva
  ON iva.id_iva = i.id_iva
LEFT JOIN sustituto_candidato sc
  ON sc.id_item = i.id_item
 AND sc.rn = 1
LEFT JOIN proveedor_principal pp
  ON pp.id_producto = p.id_producto
 AND pp.rn = 1
LEFT JOIN proveedor_count pc
  ON pc.id_producto = p.id_producto
ORDER BY cb.rn_global;
