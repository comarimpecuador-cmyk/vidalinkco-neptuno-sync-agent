/*
  NEPTUNO vademecum blob audit - READ ONLY

  Reglas:
  - Ejecutar contra una copia autorizada o la base NEPTUNO con permisos de solo lectura.
  - No exporta blobs completos.
  - Los previews son limitados y pueden resultar ilegibles.
  - No ejecutar UPDATE, INSERT, DELETE, MERGE, TRUNCATE ni DDL.
*/

SET NOCOUNT ON;

/* 1. Tablas y campos relacionados con vademecum. */
SELECT
  s.name AS schemaName,
  t.name AS tableName,
  c.column_id AS columnId,
  c.name AS columnName,
  ty.name AS dataType,
  c.max_length AS maxLength,
  c.is_nullable AS isNullable
FROM sys.tables t
JOIN sys.schemas s
  ON s.schema_id = t.schema_id
JOIN sys.columns c
  ON c.object_id = t.object_id
JOIN sys.types ty
  ON ty.user_type_id = c.user_type_id
WHERE
  t.name IN ('fa_vademecum', 'fa_seccion_vademecum', 'in_producto')
  AND (
    t.name IN ('fa_vademecum', 'fa_seccion_vademecum')
    OR c.name = 'id_vademecum'
  )
ORDER BY t.name, c.column_id;

/* 2. Conteo y estado de cabecera. */
SELECT
  COUNT_BIG(*) AS totalVademecum,
  SUM(CASE WHEN activo = 'S' THEN 1 ELSE 0 END) AS activos,
  SUM(CASE WHEN cabecera IS NULL THEN 1 ELSE 0 END) AS cabeceraNull,
  SUM(CASE WHEN cabecera IS NOT NULL AND DATALENGTH(cabecera) = 0 THEN 1 ELSE 0 END) AS cabeceraVacia,
  SUM(CASE WHEN DATALENGTH(cabecera) > 0 THEN 1 ELSE 0 END) AS cabeceraConBytes
FROM fa_vademecum;

/* 3. Bucket de tamanos de cabecera. */
SELECT
  CASE
    WHEN cabecera IS NULL THEN 'NULL'
    WHEN DATALENGTH(cabecera) = 0 THEN '0 bytes'
    WHEN DATALENGTH(cabecera) <= 100 THEN '1-100 bytes'
    WHEN DATALENGTH(cabecera) <= 1000 THEN '101-1000 bytes'
    WHEN DATALENGTH(cabecera) <= 10000 THEN '1001-10000 bytes'
    ELSE '10000+ bytes'
  END AS sizeBucket,
  COUNT_BIG(*) AS total
FROM fa_vademecum
GROUP BY
  CASE
    WHEN cabecera IS NULL THEN 'NULL'
    WHEN DATALENGTH(cabecera) = 0 THEN '0 bytes'
    WHEN DATALENGTH(cabecera) <= 100 THEN '1-100 bytes'
    WHEN DATALENGTH(cabecera) <= 1000 THEN '101-1000 bytes'
    WHEN DATALENGTH(cabecera) <= 10000 THEN '1001-10000 bytes'
    ELSE '10000+ bytes'
  END
ORDER BY MIN(CASE
  WHEN cabecera IS NULL THEN 0
  WHEN DATALENGTH(cabecera) = 0 THEN 1
  WHEN DATALENGTH(cabecera) <= 100 THEN 2
  WHEN DATALENGTH(cabecera) <= 1000 THEN 3
  WHEN DATALENGTH(cabecera) <= 10000 THEN 4
  ELSE 5
END);

/* 4. First bytes hex de cabecera. No exporta el blob completo. */
SELECT TOP (25)
  id_vademecum,
  descripcion,
  activo,
  DATALENGTH(cabecera) AS cabeceraBytes,
  sys.fn_varbintohexstr(
    SUBSTRING(CAST(cabecera AS varbinary(max)), 1, 32)
  ) AS firstBytesHex
FROM fa_vademecum
WHERE DATALENGTH(cabecera) > 0
ORDER BY id_vademecum;

/*
  5. Preview limitada de cabecera.
  Puede salir ilegible porque no se ha identificado el formato/codificacion.
*/
SELECT TOP (10)
  id_vademecum,
  descripcion,
  DATALENGTH(cabecera) AS cabeceraBytes,
  LEFT(
    CONVERT(varchar(max), CAST(cabecera AS varbinary(max))),
    200
  ) AS cabeceraPreviewPossiblyUnreadable
FROM fa_vademecum
WHERE DATALENGTH(cabecera) > 0
ORDER BY id_vademecum;

/* 6. Conteo y estado de contenido por seccion. */
SELECT
  COUNT_BIG(*) AS totalSecciones,
  COUNT_BIG(DISTINCT id_vademecum) AS vademecumsConSecciones,
  SUM(CASE WHEN contenido IS NULL THEN 1 ELSE 0 END) AS contenidoNull,
  SUM(CASE WHEN contenido IS NOT NULL AND DATALENGTH(contenido) = 0 THEN 1 ELSE 0 END) AS contenidoVacio,
  SUM(CASE WHEN DATALENGTH(contenido) > 0 THEN 1 ELSE 0 END) AS contenidoConBytes
FROM fa_seccion_vademecum;

/* 7. Bucket de tamanos de contenido. */
SELECT
  CASE
    WHEN contenido IS NULL THEN 'NULL'
    WHEN DATALENGTH(contenido) = 0 THEN '0 bytes'
    WHEN DATALENGTH(contenido) <= 100 THEN '1-100 bytes'
    WHEN DATALENGTH(contenido) <= 1000 THEN '101-1000 bytes'
    WHEN DATALENGTH(contenido) <= 10000 THEN '1001-10000 bytes'
    ELSE '10000+ bytes'
  END AS sizeBucket,
  COUNT_BIG(*) AS total
FROM fa_seccion_vademecum
GROUP BY
  CASE
    WHEN contenido IS NULL THEN 'NULL'
    WHEN DATALENGTH(contenido) = 0 THEN '0 bytes'
    WHEN DATALENGTH(contenido) <= 100 THEN '1-100 bytes'
    WHEN DATALENGTH(contenido) <= 1000 THEN '101-1000 bytes'
    WHEN DATALENGTH(contenido) <= 10000 THEN '1001-10000 bytes'
    ELSE '10000+ bytes'
  END
ORDER BY MIN(CASE
  WHEN contenido IS NULL THEN 0
  WHEN DATALENGTH(contenido) = 0 THEN 1
  WHEN DATALENGTH(contenido) <= 100 THEN 2
  WHEN DATALENGTH(contenido) <= 1000 THEN 3
  WHEN DATALENGTH(contenido) <= 10000 THEN 4
  ELSE 5
END);

/* 8. Nombres de secciones frecuentes. */
SELECT TOP (100)
  LTRIM(RTRIM(nombre)) AS sectionName,
  COUNT_BIG(*) AS total
FROM fa_seccion_vademecum
GROUP BY LTRIM(RTRIM(nombre))
ORDER BY COUNT_BIG(*) DESC, LTRIM(RTRIM(nombre));

/* 9. First bytes hex de contenido. No exporta el blob completo. */
SELECT TOP (25)
  id_seccion_vademecum,
  id_vademecum,
  secuencia,
  nombre,
  DATALENGTH(contenido) AS contenidoBytes,
  sys.fn_varbintohexstr(
    SUBSTRING(CAST(contenido AS varbinary(max)), 1, 32)
  ) AS firstBytesHex
FROM fa_seccion_vademecum
WHERE DATALENGTH(contenido) > 0
ORDER BY id_vademecum, secuencia, id_seccion_vademecum;

/*
  10. Preview limitada de contenido.
  Puede salir ilegible porque no se ha identificado el formato/codificacion.
*/
SELECT TOP (10)
  id_seccion_vademecum,
  id_vademecum,
  secuencia,
  nombre,
  DATALENGTH(contenido) AS contenidoBytes,
  LEFT(
    CONVERT(varchar(max), CAST(contenido AS varbinary(max))),
    200
  ) AS contenidoPreviewPossiblyUnreadable
FROM fa_seccion_vademecum
WHERE DATALENGTH(contenido) > 0
ORDER BY id_vademecum, secuencia, id_seccion_vademecum;

/* 11. Relacion vademecum-productos. */
SELECT TOP (250)
  p.id_producto,
  p.id_vademecum,
  v.descripcion AS vademecumNombre,
  v.activo AS vademecumActivo,
  COUNT(s.id_seccion_vademecum) AS totalSecciones
FROM in_producto p
LEFT JOIN fa_vademecum v
  ON v.id_vademecum = p.id_vademecum
LEFT JOIN fa_seccion_vademecum s
  ON s.id_vademecum = p.id_vademecum
WHERE p.id_vademecum IS NOT NULL
GROUP BY
  p.id_producto,
  p.id_vademecum,
  v.descripcion,
  v.activo
ORDER BY p.id_producto;

