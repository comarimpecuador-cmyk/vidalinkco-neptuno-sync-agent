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
