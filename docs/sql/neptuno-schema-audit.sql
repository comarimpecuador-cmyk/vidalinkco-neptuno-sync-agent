/*
  NEPTUNO schema audit - READ ONLY

  Reviews relevant tables, columns, foreign keys, catalog structures and table
  names related to product/medical metadata. A table variable organizes the
  requested names; no DML targets database tables and no DDL is executed.
*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @RelevantTables TABLE (table_name sysname PRIMARY KEY);
INSERT INTO @RelevantTables (table_name)
VALUES
    ('in_item'),
    ('in_producto'),
    ('in_estado_item'),
    ('in_nodo_clasif_1'),
    ('in_nodo_clasif_2'),
    ('in_fabricante'),
    ('co_ente'),
    ('fa_vademecum'),
    ('fa_seccion_vademecum'),
    ('pa_catalogo'),
    ('pa_item_catalogo'),
    ('in_presentacion'),
    ('in_medida'),
    ('in_concentracion'),
    ('in_item_bodega'),
    ('in_bodega'),
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

/* 1. Presence and approximate row counts. */
SELECT
    requested.table_name,
    s.name AS schema_name,
    CASE WHEN t.object_id IS NULL THEN 0 ELSE 1 END AS table_exists,
    SUM(CASE WHEN p.index_id IN (0, 1) THEN p.rows ELSE 0 END) AS approximate_rows
FROM @RelevantTables requested
LEFT JOIN sys.tables t
    ON t.name = requested.table_name
LEFT JOIN sys.schemas s
    ON s.schema_id = t.schema_id
LEFT JOIN sys.partitions p
    ON p.object_id = t.object_id
GROUP BY requested.table_name, s.name, t.object_id
ORDER BY requested.table_name;

/* 2. Columns and data types. */
SELECT
    s.name AS schema_name,
    t.name AS table_name,
    c.column_id,
    c.name AS column_name,
    ty.name AS data_type,
    c.max_length,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity
FROM sys.tables t
JOIN sys.schemas s
    ON s.schema_id = t.schema_id
JOIN sys.columns c
    ON c.object_id = t.object_id
JOIN sys.types ty
    ON ty.user_type_id = c.user_type_id
JOIN @RelevantTables requested
    ON requested.table_name = t.name
ORDER BY t.name, c.column_id;

/* 3. Foreign keys touching relevant tables. */
SELECT
    fk.name AS foreign_key_name,
    OBJECT_SCHEMA_NAME(fk.parent_object_id) AS source_schema,
    OBJECT_NAME(fk.parent_object_id) AS source_table,
    pc.name AS source_column,
    OBJECT_SCHEMA_NAME(fk.referenced_object_id) AS target_schema,
    OBJECT_NAME(fk.referenced_object_id) AS target_table,
    rc.name AS target_column,
    fk.is_disabled,
    fk.is_not_trusted
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc
    ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns pc
    ON pc.object_id = fkc.parent_object_id
   AND pc.column_id = fkc.parent_column_id
JOIN sys.columns rc
    ON rc.object_id = fkc.referenced_object_id
   AND rc.column_id = fkc.referenced_column_id
WHERE
    EXISTS (
        SELECT 1 FROM @RelevantTables r
        WHERE r.table_name = OBJECT_NAME(fk.parent_object_id)
    )
    OR EXISTS (
        SELECT 1 FROM @RelevantTables r
        WHERE r.table_name = OBJECT_NAME(fk.referenced_object_id)
    )
ORDER BY source_table, foreign_key_name, fkc.constraint_column_id;

/* 4. Structures related to presentation, measure and concentration catalogs. */
SELECT
    t.name AS table_name,
    c.column_id,
    c.name AS column_name,
    ty.name AS data_type,
    c.max_length
FROM sys.tables t
JOIN sys.columns c
    ON c.object_id = t.object_id
JOIN sys.types ty
    ON ty.user_type_id = c.user_type_id
WHERE t.name IN (
    'pa_catalogo',
    'pa_item_catalogo',
    'in_presentacion',
    'in_medida',
    'in_concentracion',
    'in_producto'
)
ORDER BY t.name, c.column_id;

/* 5. Known product codes from the confirmed sample. */
DECLARE @KnownCodes TABLE (code nvarchar(50) PRIMARY KEY);
INSERT INTO @KnownCodes (code) VALUES ('COM'), ('MG10'), ('G134');

SELECT code AS known_code
FROM @KnownCodes
ORDER BY code;

/* 6. Tables whose names indicate relevant domain data. */
SELECT
    s.name AS schema_name,
    t.name AS table_name
FROM sys.tables t
JOIN sys.schemas s
    ON s.schema_id = t.schema_id
WHERE
    LOWER(t.name) LIKE '%producto%'
    OR LOWER(t.name) LIKE '%medicina%'
    OR LOWER(t.name) LIKE '%vademecum%'
    OR LOWER(t.name) LIKE '%dosis%'
    OR LOWER(t.name) LIKE '%posologia%'
    OR LOWER(t.name) LIKE '%indicacion%'
    OR LOWER(t.name) LIKE '%advertencia%'
    OR LOWER(t.name) LIKE '%laboratorio%'
    OR LOWER(t.name) LIKE '%atributo%'
    OR LOWER(t.name) LIKE '%mensaje%'
ORDER BY t.name;
