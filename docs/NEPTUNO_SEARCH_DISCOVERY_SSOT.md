# NEPTUNO Search Discovery SSOT

Este documento fija el criterio actual para usar descubrimiento real de NEPTUNO como fuente de candidatos de busqueda y enriquecimiento. No cambia endpoints, no crea migraciones, no conecta SQL Server desde el agente y no publica productos.

## 1. Decision principal

- NEPTUNO si aporta candidatos utiles para busqueda.
- NEPTUNO no aporta sintomas utiles por producto en esta fase, porque `fa_sintoma` y relaciones directas revisadas estan vacias.
- NEPTUNO si aporta candidatos de principio activo o sustituto mediante `in_item_sustituto` -> `in_sustituto`.
- NEPTUNO si aporta proveedor, pero como dato privado operativo.
- NEPTUNO aporta vademecum metadata, pero no contenido legible todavia.
- Vidalinkco debe normalizar con selectores antes de publicar cualquier dato editorial.

## 2. Datos que vienen de NEPTUNO

- Nombre comercial
- Nombre largo
- Categoria origen
- Subcategoria origen
- Fabricante o laboratorio origen
- Vademecum metadata
- Barcode
- Precio, stock y estado
- Sustituto o principio activo candidato
- Proveedor principal y proveedores alternos
- Fechas operativas

## 3. Datos que no vienen confiables de NEPTUNO

- Sintomas utiles por producto
- Tags de busqueda por sintoma
- Intenciones tipo `fiebre`, `dolor de cabeza`, `malestar`
- Claims medicos publicos
- Indicaciones publicables sin revisar
- Dosis publicable
- Vademecum legible como texto

## 4. Sustitutos y principio activo candidato

Campos candidatos en `rawPayload`:

- `sustitutoExternalId`
- `sustitutoCodigo`
- `sustitutoDescripcion`
- `sustitutoNivel`
- `sustitutoActivo`
- `activeIngredientCandidate`
- `activeIngredientCandidateSource = "in_item_sustituto"`

Reglas:

- `sustitutoDescripcion` puede sugerir principio activo, grupo terapeutico o equivalencia NEPTUNO.
- No debe publicarse automaticamente como claim medico.
- No debe convertirse automaticamente en recomendacion medica.
- Debe pasar por selector y revision antes de entrar a `Product` publico.

Ejemplos confirmados:

- `ANALGAN COMx1GRx20` -> `ACETAMINOFEN=PARACETAMOL`
- `ACETAMINOFEN TABx500MGx100 GENF` -> `ACETAMINOFEN=PARACETAMOL`
- `LASIX TABx40MGx24` -> `FUROSEMIDA`
- `TRAMAL CAPx50MGx20` -> `CLORHIDRATO DE TRAMADOL`
- `BACTRIM FORTE TABx800/160MGx10` -> `TRIMETOPRIMA+SULFAMETOXAZOL`
- `CORDARONE COMx200MGx30` -> `AMIODARONA, CLORHIDRATO DE`

## 5. Proveedor privado

Campos privados en `rawPayload`:

- `proveedorPrincipalExternalId`
- `proveedorPrincipalNombre`
- `proveedorPrincipalActivo`
- `proveedorProductoDescripcion`
- `proveedoresCount`
- `proveedorSource = "in_proveedor_prod"`

Reglas:

- `proveedorPrincipal*` solo se llena cuando NEPTUNO marca `in_proveedor_prod.principal = 'S'`.
- Si no existe proveedor con `principal = 'S'`, `proveedorPrincipalExternalId`, `proveedorPrincipalNombre`, `proveedorPrincipalActivo` y `proveedorProductoDescripcion` deben quedar vacios/null.
- `proveedoresCount` representa el total de relaciones proveedor-producto y debe conservarse siempre que se conozca.
- No usar proveedor activo de fallback como proveedor principal.
- Si en el futuro se guarda un fallback, debe tener otro nombre claro: `proveedorCandidatoNombre`, `proveedorFallbackNombre` o `proveedorSugeridoNombre`.
- No mostrar proveedor publicamente.
- Sirve para reposicion, trazabilidad y operacion.
- No enviarlo a SEO ni PDP publica por defecto.
- No usar proveedor como argumento comercial publico sin revision.
- No todos los productos tienen proveedor principal.

CTE recomendado para el CSV v3:

```sql
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
)
```

## 6. Sintomas e intenciones

- NEPTUNO no tiene sintomas poblados en `fa_sintoma`.
- NEPTUNO no tiene una relacion producto -> sintoma util confirmada.
- Los sintomas e intenciones de busqueda deben ser editoriales en Vidalinkco.
- Deben manejarse por selector normalizado.
- Ejemplos: `fiebre`, `dolor de cabeza`, `malestar`.
- Deben ser navegacion o busqueda, no recomendacion medica automatica.

## 7. Selectores futuros necesarios en Vidalinkco

Propuesta para una fase posterior, sin implementar aqui:

- Laboratorio normalizado
- Marca comercial normalizada
- Principio activo normalizado
- Categoria publica Vidalinkco
- Subcategoria publica Vidalinkco
- Sintoma o intencion de busqueda
- Proveedor privado
- Barcode alias
- Vademecum profile

## 8. Naming tecnico vs UI

Los nombres de tablas o columnas NEPTUNO solo pueden aparecer en documentacion tecnica, mapeo interno o `rawPayload.source`. No deben usarse como nombres visibles en admin, selectores, etiquetas publicas o campos editoriales.

Nombres humanos recomendados:

- `in_item_sustituto` / `in_sustituto`: `Principio activo candidato`, `Sustituto terapeutico candidato`, `Grupo/equivalencia NEPTUNO`, `Fuente: NEPTUNO`
- `in_proveedor_prod`: `Proveedor principal`, `Proveedores alternos`, `Proveedor activo`, `Fuente: NEPTUNO`
- `fa_vademecum`: `Vademecum`, `Ficha vademecum`, `Secciones de vademecum`
- `categoriaNombre` / `subcategoriaNombre`: `Categoria origen NEPTUNO`, `Subcategoria origen NEPTUNO`

Si luego existe selector editorial en Vidalinkco, debe usar nombres propios de Vidalinkco:

- Laboratorio
- Marca comercial
- Principio activo
- Categoria publica
- Subcategoria publica
- Sintoma/intencion de busqueda
- Proveedor privado

Reglas:

- El dato tecnico conserva trazabilidad de origen.
- El admin muestra nombres claros.
- El editor selecciona entidades normalizadas, no escribe texto libre ni ve nombres crudos de tablas.
- No crear selectores con nombres de tablas NEPTUNO.
- No exponer nombres de base de datos en PDP publica, SEO, filtros publicos o textos visibles al cliente.

## 9. Flujo futuro

1. NEPTUNO importa externo.
2. El agente guarda candidatos en `rawPayload`.
3. Admin muestra candidatos con nombres claros.
4. Editor selecciona entidades normalizadas.
5. Se crea borrador `Product` seguro.
6. Producto queda `noIndex` hasta revision.
7. Se publica manualmente.

## 10. Riesgos

- Confundir sustituto con principio activo validado.
- Publicar sintomas como recomendacion medica.
- Copiar vademecum blob sin revision.
- Mostrar proveedor publicamente.
- Duplicar laboratorios por texto libre.
- Duplicar categorias por texto libre.
- Crear selectores con nombres tecnicos de NEPTUNO.
- Crear productos publicos masivos sin revision.
- Mezclar categoria origen NEPTUNO con categoria publica Vidalinkco.

## 11. Recomendacion

- Cerrar este SSOT antes de tocar `vidalinkco-web`.
- Luego hacer catalogo v3 smoke con sustituto/principio activo candidato, proveedor privado principal si existe y count de proveedores.
- Luego decidir UI/selectores en `vidalinkco-web`.

## Descubrimiento real resumido

- `fa_sintoma`: existe, 0 filas.
- `fa_auxilios_producto`: existe, 0 filas.
- `cl_asoc_producto_diag`: existe, 0 filas.
- `fa_cuadro_clinico`: 206 filas, sin relacion producto -> busqueda publica confirmada.
- `cl_patologia`: 71 filas, sin relacion util confirmada para productos de prueba.
- `mc_plan_producto`: 861 filas, no aplico a productos de prueba.
- `in_item_sustituto`: 49.268 filas.
- `in_sustituto`: 2.867 filas.
- `in_proveedor_prod`: 578.806 filas.
- `fa_seccion_vademecum`: contiene secciones como `COMPOSICION`, `INDICACIONES`, `CONTRAINDICACIONES`, `DOSIS`, `ACCION TERAPEUTICA`; el contenido esta en campo `image/blob` y no se pudo leer como texto simple en esta fase.
