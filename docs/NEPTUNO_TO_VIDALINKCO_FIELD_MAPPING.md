# NEPTUNO to Vidalinkco Field Mapping

## Contract boundary

- `Product` remains the public Vidalinkco SSOT.
- `ExternalProduct`, staging and enrichment data are internal.
- This audit pack does not create, update or publish Vidalinkco products.
- Do not invent a description.
- Do not put the word `NEPTUNO` into a public product description.
- Vademecum blobs are not publishable until decoding is reliable and reviewed.
- Vademecum section names are stored only as pending metadata.
- Internal codes such as `COM`, `MG10` and `G134` remain source codes. Human
  labels must come from `pa_item_catalogo`.
- Any medical or editorial field requires human review before publication.

## Mapping matrix

`Current Vidalinkco destination` reflects the existing sync-agent contract in
this repository. `Recommended new field` is documentary guidance only and does
not authorize a schema change.

| NEPTUNO field | Example 9102 | Meaning | Current Vidalinkco destination | Recommended new field if missing | Visibility | Human review | Autofill rule |
|---|---|---|---|---|---|---|---|
| `in_item.id_item` | `9102` | Stable source product ID | `ExternalProduct.externalId` | None | Admin-only | No | Copy exactly as string |
| `in_item.descripcion` | `GEMFIBROZILO COMx600MGx20 ECUA` | Original commercial name | `nombreOriginal` / external staging | None | Staging | Yes before public use | Copy as source name; never as invented public description |
| `in_item.descripcion_larga` | Pending local audit | Source long name | `nombreLargo` / external staging | None | Staging | Yes | Copy only when present; no generated prose |
| `in_item.id_estado_item` | State resolves to `ACT FRANQUICIA` | Source status ID | `estadoExternalId` | None | Admin-only | No | Copy exact ID |
| `in_estado_item.descripcion` | `ACT FRANQUICIA` | Human source status | `estadoNombre` | None | Admin-only | Yes | Copy exact label |
| `in_estado_item.puede_vender` | `S` | Source can-sell flag | `puedeVender` | None | Admin-only | Yes | Normalize only known boolean values |
| `in_item.id_clasif_1` | Pending local audit | Source category ID | `categoriaExternalId` | None | Staging | Yes | Never map directly to public category |
| `in_nodo_clasif_1.descripcion` | Pending local audit | Source category label | `categoriaNombre` | None | Staging | Yes | Candidate for normalized category |
| `in_item.id_clasif_2` | Pending local audit | Source subcategory ID | `subcategoriaExternalId` | None | Staging | Yes | Copy exact ID |
| `in_nodo_clasif_2.descripcion` | Pending local audit | Source subcategory label | `subcategoriaNombre` | None | Staging | Yes | Candidate only |
| `in_producto.presentacion` source code | `COM` | Presentation code | `presentacion` accepts source text | `rawPayload.presentacionCodigo` | Staging | Yes | Preserve code; resolve label from `pa_item_catalogo` |
| `pa_item_catalogo` presentation label | `COMPRIMIDOS` | Human presentation | `presentacion` | None | Staging/public after review | Yes | Exact catalog-code match only |
| `in_producto.medida` source code | `MG10` | Measure code | `medida` accepts source text | `rawPayload.medidaCodigo` | Staging | Yes | Preserve code; resolve label from catalog |
| `pa_item_catalogo` measure label | `600 MG` | Human measure | `medida` | None | Staging/public after review | Yes | Exact catalog-code match only |
| `in_producto.concentracion` source code | `G134` | Concentration code | `concentracion` accepts source text | `rawPayload.concentracionCodigo` | Staging | Yes | Preserve code; resolve label from catalog |
| `pa_item_catalogo` concentration label | `600 MG` | Human concentration | `concentracion` | None | Staging/public after review | Yes | Exact catalog-code match only |
| `in_producto.num_fraccion` | Verify locally | Units/fractions per package | `unidadesPorCaja` | None | Staging | Yes | Use confirmed column value; never parse product name as truth |
| `in_producto.generico` | Pending local audit | Generic flag | `generico` | None | Staging | Yes | Preserve source value |
| `in_producto.restric_medica` | Pending local audit | Medical restriction | `restriccionMedica` | None | Admin-only | Required | Never convert into public medical advice |
| `in_producto.requiere_medico` | Pending local audit | Medical/prescription requirement | `requiereMedico` | None | Admin-only | Required | Normalize known boolean values only |
| `in_producto.venta_sin_stock` | Pending local audit | Out-of-stock sale policy | `ventaSinStock` | None | Admin-only | Yes | Preserve source value |
| `in_producto.cronico` | Pending local audit | Chronic-product source flag | `cronico` | None | Admin-only | Required | No automatic public medical claim |
| `in_producto.id_fabricante` | Pending local audit | Manufacturer/laboratory ID | `fabricanteExternalId` | None | Staging | Yes | Copy exact ID |
| `in_fabricante.mnemonico` | Pending local audit | Manufacturer code | `fabricanteCodigo` | None | Staging | Yes | Copy exact code |
| `co_ente.nombre_completo` | Pending local audit | Manufacturer/laboratory name | `fabricanteNombre` | None | Staging/public after normalization | Yes | Candidate for normalized laboratory |
| `in_producto.id_vademecum` | `1809` | Vademecum record ID | `vademecumExternalId` | None | Admin-only | Yes | Copy exact ID |
| `fa_vademecum.descripcion` | `GEMFIBROZILO` | Vademecum name | `vademecumNombre` | None | Admin-only/Staging | Required | Metadata only, not a public claim |
| `fa_vademecum.activo` | Pending local audit | Vademecum active flag | `rawPayload.vademecumActivo` | None | Admin-only | Yes | Preserve source |
| `fa_vademecum.cabecera` | Opaque binary | Vademecum header blob | Not sent | `rawPayload.vademecumCabeceraDecodeStatus` | Admin-only | Required | Store byte metadata/status only |
| `fa_seccion_vademecum.nombre` | `ACCION`, `INDICACIONES`, `CONTRAINDICACIONES Y ADVERTENCIAS`, `REACCIONES ADVERSAS`, `DOSIS`, `PRESENTACIONES` | Section structure | Not in current payload | `rawPayload.vademecumSectionMetadata[]` | Admin-only | Required | Store ID/name/sequence/byte count/status only |
| `fa_seccion_vademecum.contenido` | Opaque binary | Medical section blob | Not sent | `rawPayload.vademecumDecodeStatus` | Admin-only | Required | Pending reliable decoding; never autofill public text |
| `in_item_bodega.id_bodega` | `1` | Source warehouse ID | `bodegaExternalId` | None | Admin-only | No | Copy exact ID |
| `in_bodega.nombre` | Pending local audit | Warehouse name | Not in current top-level payload | `rawPayload.bodegaNombre` | Admin-only | No | Use `nombre`, not nonexistent `descripcion` |
| `in_bodega.nombre_largo` | If column exists | Long warehouse name | Not in current payload | `rawPayload.bodegaNombreLargo` | Admin-only | No | Fill only when column exists |
| `in_bodega.nombre_comercial` | If column exists | Commercial warehouse name | Not in current payload | `rawPayload.bodegaNombreComercial` | Admin-only | Yes | Fill only when column exists |
| `in_item_bodega.habilitado` | `S` | Product enabled in warehouse | `rawPayload.bodegaHabilitado` | None | Admin-only | No | Normalize known boolean values |
| `in_item_bodega.stock_unidad` | `1` | Unit stock | `stockUnidad` / `ProductLiveState` | None | Admin-only operational | No | Copy non-negative number |
| `in_item_bodega.stock_fraccion` | `3` | Fraction stock | `stockFraccion` / `ProductLiveState` | None | Admin-only operational | No | Copy non-negative number |
| Requested extra product tables | Pending audit | Commercial, message, aid, attribute, plan, agreement or complement data | No current destination | `rawPayload.auditExtras` after contract review | Admin-only | Required | Do not autofill until relationship and semantics are confirmed |

## Publication rules

- Public: only reviewed data intentionally copied into public `Product`.
- Admin-only: source IDs, warehouse state, raw codes, blob metadata and extra
  table data.
- Staging: names, presentation, measure, concentration, classifications,
  manufacturer and vademecum metadata as review candidates.

## Description rule

There is no automatic rule that can create a public description from product
name, vademecum name, section names, manufacturer or catalog codes. If NEPTUNO
does not provide a confirmed editorial description, the public description
remains empty or keeps the existing Vidalinkco editorial value.

The word `NEPTUNO` is technical provenance and must not be inserted into public
description, SEO copy, PDP copy or customer-facing claims.

## Medical safety rule

Risk classification, possible causes, indications, contraindications, dose and
medical recommendations must remain separate from raw source metadata. Opaque
blobs and section names are not medical evidence suitable for automatic public
content. Any decoded medical text requires reliable extraction, provenance,
human clinical/editorial review and an explicit publication workflow.
