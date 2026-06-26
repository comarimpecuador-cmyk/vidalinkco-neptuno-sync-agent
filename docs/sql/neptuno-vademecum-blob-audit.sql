/*
  NEPTUNO vademecum blob audit - READ ONLY

  Uses bounded byte previews only. It does not convert blob content into final
  medical text and does not export complete blobs.
*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @ProductId bigint = 9102;
DECLARE @VademecumId bigint = NULL;

SET @VademecumId = COALESCE(
    @VademecumId,
    (SELECT TOP (1) p.id_vademecum FROM in_producto p WHERE p.id_producto = @ProductId)
);

/* 1. Main vademecum metadata and bounded header preview. */
SELECT
    v.id_vademecum,
    v.descripcion,
    v.id_fabricante,
    v.activo,
    DATALENGTH(v.cabecera) AS cabecera_bytes,
    sys.fn_varbintohexstr(
        SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 64)
    ) AS cabecera_hex_preview,
    REPLACE(REPLACE(REPLACE(
        CONVERT(varchar(160), SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 160)),
        CHAR(13), '.'),
        CHAR(10), '.'),
        CHAR(9), '.') AS cabecera_raw_preview_possibly_unreadable,
    CASE
        WHEN SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 2) = 0x1F8B THEN 'gzip-signature'
        WHEN SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 4) = 0x504B0304 THEN 'zip-signature'
        WHEN SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 4) = 0x25504446 THEN 'pdf-signature'
        WHEN SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 4) = 0x89504E47 THEN 'png-signature'
        WHEN SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 3) = 0xFFD8FF THEN 'jpeg-signature'
        WHEN SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 4) = 0xD0CF11E0 THEN 'ole-compound-signature'
        WHEN SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 3) = 0xEFBBBF THEN 'utf8-bom'
        WHEN SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 2) IN (0xFFFE, 0xFEFF) THEN 'utf16-bom'
        WHEN SUBSTRING(CAST(v.cabecera AS varbinary(max)), 1, 2) IN (0x7801, 0x785E, 0x789C, 0x78DA) THEN 'possible-zlib-signature'
        ELSE 'unknown-binary-or-proprietary'
    END AS format_detection,
    'PENDING_RELIABLE_DECODING_DO_NOT_PUBLISH' AS publication_status
FROM fa_vademecum v
WHERE v.id_vademecum = @VademecumId;

/* 2. Section metadata and bounded content previews. */
SELECT
    s.id_seccion_vademecum,
    s.id_vademecum,
    s.secuencia,
    s.nombre,
    DATALENGTH(s.contenido) AS contenido_bytes,
    sys.fn_varbintohexstr(
        SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 64)
    ) AS contenido_hex_preview,
    REPLACE(REPLACE(REPLACE(
        CONVERT(varchar(160), SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 160)),
        CHAR(13), '.'),
        CHAR(10), '.'),
        CHAR(9), '.') AS contenido_raw_preview_possibly_unreadable,
    CASE
        WHEN SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 2) = 0x1F8B THEN 'gzip-signature'
        WHEN SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 4) = 0x504B0304 THEN 'zip-signature'
        WHEN SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 4) = 0x25504446 THEN 'pdf-signature'
        WHEN SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 4) = 0x89504E47 THEN 'png-signature'
        WHEN SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 3) = 0xFFD8FF THEN 'jpeg-signature'
        WHEN SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 4) = 0xD0CF11E0 THEN 'ole-compound-signature'
        WHEN SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 3) = 0xEFBBBF THEN 'utf8-bom'
        WHEN SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 2) IN (0xFFFE, 0xFEFF) THEN 'utf16-bom'
        WHEN SUBSTRING(CAST(s.contenido AS varbinary(max)), 1, 2) IN (0x7801, 0x785E, 0x789C, 0x78DA) THEN 'possible-zlib-signature'
        ELSE 'unknown-binary-or-proprietary'
    END AS format_detection,
    'PENDING_RELIABLE_DECODING_DO_NOT_PUBLISH' AS publication_status
FROM fa_seccion_vademecum s
WHERE s.id_vademecum = @VademecumId
ORDER BY s.secuencia, s.id_seccion_vademecum;

/* 3. Aggregate status for operator review. */
SELECT
    @ProductId AS product_id,
    @VademecumId AS vademecum_id,
    COUNT(*) AS section_count,
    SUM(CASE WHEN contenido IS NULL THEN 1 ELSE 0 END) AS null_content_count,
    SUM(CASE WHEN DATALENGTH(contenido) > 0 THEN 1 ELSE 0 END) AS sections_with_bytes,
    'Content remains pending reliable decoding' AS conclusion
FROM fa_seccion_vademecum
WHERE id_vademecum = @VademecumId;
