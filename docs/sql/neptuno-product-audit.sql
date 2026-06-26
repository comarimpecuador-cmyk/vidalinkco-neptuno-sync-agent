/*
  NEPTUNO product audit - READ ONLY

  Defaults confirmed for pharmacy PC:
  - Database: NEPTUNO
  - ProductId: 9102
  - Optional VademecumId: 1809

  This script executes SELECT statements against NEPTUNO. Table variables and
  cursors organize the local audit batch; no DML targets database tables. It
  does not send data to Vidalinkco or persist audit output in SQL Server.
*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @ProductId bigint = 9102;
DECLARE @VademecumId bigint = NULL;

/* 1. Main product, state, classification, manufacturer and vademecum. */
SELECT
    i.*,
    p.*,
    ei.descripcion AS estado_descripcion,
    ei.puede_vender,
    c1.descripcion AS clasificacion_1_descripcion,
    c2.descripcion AS clasificacion_2_descripcion,
    f.mnemonico AS fabricante_codigo,
    fabricante_ente.nombre_completo AS fabricante_nombre,
    v.descripcion AS vademecum_descripcion,
    v.activo AS vademecum_activo,
    DATALENGTH(v.cabecera) AS vademecum_cabecera_bytes,
    sys.fn_varbintohexstr(
        SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 32)
    ) AS vademecum_cabecera_first_bytes_hex
FROM in_item i
LEFT JOIN in_producto p
    ON p.id_producto = i.id_item
LEFT JOIN in_estado_item ei
    ON ei.id_estado_item = i.id_estado_item
LEFT JOIN in_nodo_clasif_1 c1
    ON c1.id_nodo_clasif_1 = i.id_clasif_1
LEFT JOIN in_nodo_clasif_2 c2
    ON c2.id_nodo_clasif_2 = i.id_clasif_2
LEFT JOIN in_fabricante f
    ON f.id_ente = p.id_fabricante
LEFT JOIN co_ente fabricante_ente
    ON fabricante_ente.id_ente = f.id_ente
LEFT JOIN fa_vademecum v
    ON v.id_vademecum = COALESCE(@VademecumId, p.id_vademecum)
WHERE i.id_item = @ProductId;

/* 2. Stock and warehouse names. in_bodega.descripcion is intentionally not used. */
DECLARE @WarehouseNameLongExpression nvarchar(300) =
    CASE
        WHEN COL_LENGTH('in_bodega', 'nombre_largo') IS NOT NULL
            THEN N'CAST(b.nombre_largo AS nvarchar(500))'
        ELSE N'CAST(NULL AS nvarchar(500))'
    END;
DECLARE @WarehouseCommercialExpression nvarchar(300) =
    CASE
        WHEN COL_LENGTH('in_bodega', 'nombre_comercial') IS NOT NULL
            THEN N'CAST(b.nombre_comercial AS nvarchar(500))'
        ELSE N'CAST(NULL AS nvarchar(500))'
    END;
DECLARE @StockSql nvarchar(max) = N'
SELECT
    ib.*,
    CAST(b.nombre AS nvarchar(500)) AS bodega_nombre,
    ' + @WarehouseNameLongExpression + N' AS bodega_nombre_largo,
    ' + @WarehouseCommercialExpression + N' AS bodega_nombre_comercial
FROM in_item_bodega ib
LEFT JOIN in_bodega b
    ON b.id_bodega = ib.id_bodega
WHERE ib.id_item = @ProductId
ORDER BY ib.id_bodega;';
EXEC sys.sp_executesql @StockSql, N'@ProductId bigint', @ProductId;

/* 3. Vademecum sections: metadata and bounded hex only, never final text. */
SELECT
    s.id_seccion_vademecum,
    s.id_vademecum,
    s.secuencia,
    s.nombre,
    DATALENGTH(s.contenido) AS contenido_bytes,
    sys.fn_varbintohexstr(
        SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 32)
    ) AS contenido_first_bytes_hex,
    'PENDING_RELIABLE_DECODING_DO_NOT_PUBLISH' AS publication_status
FROM fa_seccion_vademecum s
WHERE s.id_vademecum = COALESCE(
    @VademecumId,
    (SELECT TOP (1) p.id_vademecum FROM in_producto p WHERE p.id_producto = @ProductId)
)
ORDER BY s.secuencia, s.id_seccion_vademecum;

/*
  4. Presentation/measure/concentration catalogs.
  The live installation has used codes such as COM, MG10 and G134. Because
  pa_item_catalogo schemas vary by NEPTUNO version, inspect all textual columns
  and return exact matches for the values stored in in_producto.
*/
DECLARE @ProductCodes TABLE (code nvarchar(4000) PRIMARY KEY);
INSERT INTO @ProductCodes (code)
SELECT DISTINCT product_values.value
FROM (
    SELECT NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), presentacion))), '') AS value
    FROM in_producto WHERE id_producto = @ProductId
    UNION ALL
    SELECT NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), medida))), '')
    FROM in_producto WHERE id_producto = @ProductId
    UNION ALL
    SELECT NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), concentracion))), '')
    FROM in_producto WHERE id_producto = @ProductId
) product_values
WHERE product_values.value IS NOT NULL;

SELECT code AS product_catalog_code
FROM @ProductCodes
ORDER BY code;

DECLARE @CatalogTable sysname;
DECLARE catalog_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT table_name
FROM (VALUES ('pa_catalogo'), ('pa_item_catalogo')) requested(table_name)
WHERE OBJECT_ID(table_name, 'U') IS NOT NULL;

OPEN catalog_cursor;
FETCH NEXT FROM catalog_cursor INTO @CatalogTable;
WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @CatalogPredicate nvarchar(max);
    SELECT @CatalogPredicate = STUFF((
        SELECT
            N' OR @Code = LTRIM(RTRIM(CONVERT(nvarchar(4000), '
            + QUOTENAME(col.name) + N')))'
        FROM sys.columns col
        JOIN sys.types typ
            ON typ.user_type_id = col.user_type_id
        WHERE
            col.object_id = OBJECT_ID(@CatalogTable)
            AND typ.name IN ('char', 'nchar', 'varchar', 'nvarchar')
        ORDER BY col.column_id
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 4, '');

    IF NULLIF(@CatalogPredicate, '') IS NOT NULL
    BEGIN
        DECLARE @Code nvarchar(4000);
        DECLARE code_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT code FROM @ProductCodes;

        OPEN code_cursor;
        FETCH NEXT FROM code_cursor INTO @Code;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @CatalogSql nvarchar(max) =
                N'SELECT TOP (500) ' + QUOTENAME(@CatalogTable, '''') + N' AS source_table, * '
                + N'FROM ' + QUOTENAME(@CatalogTable) + N' WHERE ' + @CatalogPredicate + N';';
            EXEC sys.sp_executesql @CatalogSql, N'@Code nvarchar(4000)', @Code;

            FETCH NEXT FROM code_cursor INTO @Code;
        END;
        CLOSE code_cursor;
        DEALLOCATE code_cursor;
    END;

    FETCH NEXT FROM catalog_cursor INTO @CatalogTable;
END;
CLOSE catalog_cursor;
DEALLOCATE catalog_cursor;

/* 5. Extra tables: schema presence and direct product-reference columns. */
DECLARE @ExtraTables TABLE (table_name sysname PRIMARY KEY);
INSERT INTO @ExtraTables (table_name)
VALUES
    ('in_producto_comercial'),
    ('ve_mensaje_producto'),
    ('ve_mensaje_producto_cab'),
    ('ve_mensaje_producto_det'),
    ('ve_producto_mensaje'),
    ('fa_auxilios_producto'),
    ('fa_primeros_aux'),
    ('in_valor_atributo_item'),
    ('mc_plan_producto'),
    ('in_producto_convenio'),
    ('in_item_complement'),
    ('in_item_datos_asegensa');

SELECT
    e.table_name,
    CASE WHEN OBJECT_ID(e.table_name, 'U') IS NULL THEN 0 ELSE 1 END AS table_exists,
    direct_reference.column_name AS direct_product_reference
FROM @ExtraTables e
OUTER APPLY (
    SELECT TOP (1) c.name AS column_name
    FROM sys.columns c
    WHERE
        c.object_id = OBJECT_ID(e.table_name, 'U')
        AND c.name IN ('id_producto', 'id_item', 'id_producto_comercial')
    ORDER BY CASE c.name
        WHEN 'id_producto' THEN 1
        WHEN 'id_item' THEN 2
        ELSE 3
    END
) direct_reference
ORDER BY e.table_name;

DECLARE @ExtraTable sysname;
DECLARE @ReferenceColumn sysname;
DECLARE extra_cursor CURSOR LOCAL FAST_FORWARD FOR
SELECT
    e.table_name,
    direct_reference.column_name
FROM @ExtraTables e
CROSS APPLY (
    SELECT TOP (1) c.name AS column_name
    FROM sys.columns c
    WHERE
        c.object_id = OBJECT_ID(e.table_name, 'U')
        AND c.name IN ('id_producto', 'id_item', 'id_producto_comercial')
    ORDER BY CASE c.name
        WHEN 'id_producto' THEN 1
        WHEN 'id_item' THEN 2
        ELSE 3
    END
) direct_reference;

OPEN extra_cursor;
FETCH NEXT FROM extra_cursor INTO @ExtraTable, @ReferenceColumn;
WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @ExtraSql nvarchar(max) =
        N'SELECT TOP (200) ' + QUOTENAME(@ExtraTable, '''') + N' AS source_table, * '
        + N'FROM ' + QUOTENAME(@ExtraTable)
        + N' WHERE ' + QUOTENAME(@ReferenceColumn) + N' = @ProductId;';
    EXEC sys.sp_executesql @ExtraSql, N'@ProductId bigint', @ProductId;

    FETCH NEXT FROM extra_cursor INTO @ExtraTable, @ReferenceColumn;
END;
CLOSE extra_cursor;
DEALLOCATE extra_cursor;
