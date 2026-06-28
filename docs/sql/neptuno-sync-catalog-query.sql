/*
  NEPTUNO Phase 9A-1B catalog query.
  Runtime parameters: @MaxProducts (int) and optional parameterized
  @ExternalIdN values injected at the marked filter placeholder.
  Read-only metadata only. Vademecum binary columns are intentionally absent.

  TODO pharmacy audit:
  Resolve the exact pa_item_catalogo key/label columns before populating
  presentacionNombre, medidaNombre and concentracionNombre. The confirmed
  source codes remain available without guessing the catalog schema.
*/

WITH vademecum_sections AS (
    SELECT
        v.id_vademecum,
        STUFF((
            SELECT
                '|' + LTRIM(RTRIM(CAST(s.nombre AS varchar(250))))
            FROM fa_seccion_vademecum AS s
            WHERE s.id_vademecum = v.id_vademecum
              AND s.nombre IS NOT NULL
            ORDER BY s.secuencia, s.id_seccion_vademecum
            FOR XML PATH(''), TYPE
        ).value('.', 'varchar(max)'), 1, 1, '') AS vademecumSectionNames
    FROM fa_vademecum AS v
)
SELECT TOP (@MaxProducts)
    CAST(i.id_item AS varchar(50)) AS externalId,
    CAST(i.descripcion AS varchar(250)) AS nombreOriginal,
    CAST(i.descripcion_larga AS varchar(500)) AS nombreLargo,
    CAST(i.precio AS decimal(18, 4)) AS precioOrigen,
    CAST(i.aplica_iva AS varchar(10)) AS aplicaIvaOrigen,
    CAST(i.id_iva AS varchar(50)) AS ivaOrigenId,
    CAST(i.id_clasif_1 AS varchar(50)) AS categoriaExternalId,
    CAST(c1.descripcion AS varchar(180)) AS categoriaNombre,
    CAST(i.id_clasif_2 AS varchar(50)) AS subcategoriaExternalId,
    CAST(c2.descripcion AS varchar(180)) AS subcategoriaNombre,
    CAST(i.id_estado_item AS varchar(50)) AS estadoExternalId,
    CAST(ei.descripcion AS varchar(120)) AS estadoNombre,
    CAST(ei.puede_vender AS varchar(10)) AS puedeVender,
    CAST(p.presentacion AS varchar(120)) AS presentacionCodigo,
    CAST(NULL AS varchar(250)) AS presentacionNombre,
    CAST(p.medida AS varchar(120)) AS medidaCodigo,
    CAST(NULL AS varchar(250)) AS medidaNombre,
    CAST(p.concentracion AS varchar(120)) AS concentracionCodigo,
    CAST(NULL AS varchar(250)) AS concentracionNombre,
    CAST(p.num_fraccion AS decimal(18, 4)) AS unidadesPorCaja,
    CAST(p.generico AS varchar(10)) AS generico,
    CAST(p.restric_medica AS varchar(50)) AS restriccionMedica,
    CAST(p.requiere_medico AS varchar(10)) AS requiereMedico,
    CAST(p.cronico AS varchar(10)) AS cronico,
    CAST(p.id_fabricante AS varchar(50)) AS fabricanteExternalId,
    CAST(f.mnemonico AS varchar(80)) AS fabricanteCodigo,
    CAST(fabricante_ente.nombre_completo AS varchar(250)) AS fabricanteNombre,
    CAST(p.id_vademecum AS varchar(50)) AS vademecumExternalId,
    CAST(v.descripcion AS varchar(250)) AS vademecumNombre,
    CAST(vs.vademecumSectionNames AS varchar(max)) AS vademecumSectionNames
FROM in_item AS i
LEFT JOIN in_producto AS p
    ON p.id_producto = i.id_item
LEFT JOIN in_estado_item AS ei
    ON ei.id_estado_item = i.id_estado_item
LEFT JOIN in_nodo_clasif_1 AS c1
    ON c1.id_nodo_clasif_1 = i.id_clasif_1
LEFT JOIN in_nodo_clasif_2 AS c2
    ON c2.id_nodo_clasif_2 = i.id_clasif_2
LEFT JOIN in_fabricante AS f
    ON f.id_ente = p.id_fabricante
LEFT JOIN co_ente AS fabricante_ente
    ON fabricante_ente.id_ente = f.id_ente
LEFT JOIN fa_vademecum AS v
    ON v.id_vademecum = p.id_vademecum
LEFT JOIN vademecum_sections AS vs
    ON vs.id_vademecum = p.id_vademecum
WHERE i.id_item IS NOT NULL
  AND i.descripcion IS NOT NULL
  AND i.precio IS NOT NULL
/*__EXTERNAL_IDS_FILTER__*/
ORDER BY i.id_item;
