# Vidalinkco Field Gap Analysis

Este documento analiza informacion util que NEPTUNO puede aportar a Vidalinkco sin asumir publicacion automatica. El agente escribe datos externos para `ExternalProduct` / `ProductLiveState` y revision admin; no modifica `Product` publico.

## A. Lo que Vidalinkco ya tiene como producto publico

- Nombre
- Slug
- Descripcion
- Precio
- IVA
- Categoria
- Marca
- Imagen
- Descuento
- Stock
- Activo, `noIndex` y SEO manual

## B. Informacion util que NEPTUNO trae para futuro uso

- Presentacion
- Medida
- Concentracion
- Unidades por caja o fraccion
- Laboratorio o fabricante
- Codigo de barra
- Categoria origen
- Subcategoria origen
- Requiere medico
- Restriccion medica
- Cronico
- Venta sin stock
- Vademecum
- Estado NEPTUNO y puede vender
- Ultima venta, ultima compra, ultima transferencia y ultima actualizacion
- Ubicacion o bodega
- IVA origen y tasa
- Frescura del dato
- Sustituto o principio activo candidato
- Proveedor privado principal o alternos

## C. Utilidad para compra y operacion

- Disponibilidad
- Stock fraccionado
- Producto habilitado por bodega
- Puede vender
- Precio operativo
- Codigo de barra
- Ultima actualizacion

## D. Utilidad para contenido y ficha de producto

- Presentacion
- Concentracion
- Medida
- Fabricante o laboratorio
- Vademecum metadata
- Generico
- Cronico
- Requiere medico

## E. Lo que no debe publicarse automaticamente

- Costos
- Margenes
- Utilidad
- Datos internos de compra
- Blobs de vademecum
- Claims medicos no revisados
- Recomendaciones automaticas de uso

## F. Recomendacion futura

Crear una capa editorial de conversion `ExternalProduct` -> `Product`.

Esa capa debe decidir:

- Nombre publico
- Slug
- SEO title
- Descripcion
- Categoria Vidalinkco
- Marca Vidalinkco
- Imagen
- Si requiere advertencia
- Si se puede vender online
- Precio base e IVA compatibles con Vidalinkco

Nunca copiar todo automaticamente. Si NEPTUNO entrega precio base, la conversion debe mapearlo a `Product.precio` base y `Product.iva`. Si NEPTUNO entrega precio final, debe convertirlo o marcarlo correctamente para no duplicar IVA.

## Catalog CSV v3 search candidates

NEPTUNO puede aportar candidatos utiles para busqueda, pero no verdades editoriales finales.

Campos de `rawPayload` para sustituto/principio activo candidato:

- `sustitutoExternalId`
- `sustitutoCodigo`
- `sustitutoDescripcion`
- `sustitutoNivel`
- `sustitutoActivo`
- `activeIngredientCandidate`
- `activeIngredientCandidateSource`

Campos de `rawPayload` para proveedor privado:

- `proveedorPrincipalExternalId`
- `proveedorPrincipalNombre`
- `proveedorPrincipalActivo`
- `proveedorProductoDescripcion`
- `proveedoresCount`
- `proveedorSource`

Uso futuro recomendado:

- Mostrar candidatos en admin con nombres claros para humanos.
- Normalizar mediante selectores antes de publicar.
- Mantener proveedor como dato privado operativo.
- `proveedorPrincipal*` debe representar solo proveedor marcado como principal en NEPTUNO (`principal = 'S'`).
- Si no hay proveedor principal, los campos `proveedorPrincipal*` deben quedar vacios/null; no se completan con fallback activo.
- `proveedoresCount` si puede conservarse siempre como total de relaciones proveedor-producto.
- Mantener sintomas/intenciones como entidades editoriales de Vidalinkco, no derivadas automaticamente desde NEPTUNO.
- No exponer nombres de tablas NEPTUNO en PDP publica, SEO, filtros publicos ni textos visibles al cliente.
