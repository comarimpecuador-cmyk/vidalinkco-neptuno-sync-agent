# NEPTUNO Vademecum Blob Audit

## Objetivo

Documentar de forma repetible y read-only la estructura binaria de vademecum en NEPTUNO. Esta fase no publica contenido medico, no envia blobs a Vidalinkco, no cambia endpoints y no modifica el contrato de sincronizacion.

## Tablas y campos detectados

`fa_vademecum`:

- `id_vademecum`
- `descripcion`
- `cabecera` tipo `image`
- `id_fabricante`
- `activo`

`fa_seccion_vademecum`:

- `id_seccion_vademecum`
- `id_vademecum`
- `secuencia`
- `nombre`
- `contenido` tipo `image`

Relacion con productos:

- `in_producto.id_vademecum`

## Hallazgos reales de fa_vademecum

- Total de vademecum: `6753`
- Activos: `6753`
- `cabecera` null: `0`
- `cabecera` vacia: `0`
- `cabecera` con bytes: `6753`
- Todas las cabeceras caen en el bucket `101-1000 bytes`
- Los ejemplos auditados tenian `cabeceraBytes = 322`
- `firstBytesHex` no parece RTF, HTML ni UTF-8 directo
- El preview con `CONVERT(varchar(max), CAST(cabecera AS varbinary(max)))` resulta ilegible/binario

## Hallazgos reales de fa_seccion_vademecum

- Total de secciones: `36415`
- Vademecum con secciones: `6743`
- `contenido` null: `118`
- `contenido` vacio: `0`
- `contenido` con bytes: `36297`

Buckets de contenido:

- `101-1000 bytes`: `32499`
- `1001-10000 bytes`: `3779`
- `NULL`: `118`
- `10000+ bytes`: `19`

El preview directo resulta ilegible/binario y `firstBytesHex` no parece RTF, HTML ni UTF-8 directo.

## Secciones frecuentes

- INDICACIONES
- CONTRAINDICACIONES
- PRESENTACION
- COMPOSICION
- DOSIS
- POSOLOGIA
- PRECAUCIONES
- EFECTOS SECUNDARIOS
- REACCIONES ADVERSAS
- DESCRIPCION
- ADVERTENCIAS
- INTERACCIONES
- FARMACOLOGIA
- EMBARAZO Y LACTANCIA
- MODO DE USO

## Conclusion

`fa_vademecum.cabecera` y `fa_seccion_vademecum.contenido` no son publicables ni legibles directamente. Deben tratarse como binarios no decodificados hasta contar con un extractor validado y evidencia suficiente del formato.

La estructura relacional y los nombres de seccion son utiles para auditoria y organizacion interna, pero no convierten el contenido binario en texto medico publicable.

## Hipotesis tecnicas

El contenido puede usar una o varias de estas representaciones:

- Compresion
- Serializacion binaria
- Formato propietario de NEPTUNO
- Codificacion antigua o no Unicode
- Blob interno generado por un componente de escritorio
- Contenedor con encabezado propio y contenido embebido

Ninguna hipotesis debe asumirse como confirmada sin comparar bytes, identificar firmas y validar un extractor contra contenido visible en NEPTUNO.

## Reglas de seguridad y publicacion

- No publicar contenido medico automatico desde estos blobs.
- No enviar `cabecera` ni `contenido` a Vidalinkco en la sincronizacion actual.
- No convertir previews ilegibles en texto visible.
- No inferir indicaciones, dosis, contraindicaciones ni recomendaciones desde bytes no decodificados.
- No guardar blobs en Git, tickets, chats o logs.
- No usar nombres de seccion como claims medicos.

## Decision recomendada

- Usar `vademecumExternalId` y `vademecumNombre` como metadata o candidato de revision.
- Usar nombres de seccion solo como estructura interna.
- Mantener el contenido publico como editorial.
- Considerar contenido extraido solo despues de implementar y validar un extractor reproducible.
- Someter cualquier contenido medico extraido a revision antes de publicarlo.

## Herramientas de esta fase

- SQL read-only: `docs/sql/vademecum-blob-audit.sql`
- Auditor formal con previews acotados:
  `scripts/audit-neptuno-vademecum-blob.ps1`
- SQL formal para PC farmacia:
  `docs/sql/neptuno-vademecum-blob-audit.sql`
- Exportador binario local anterior y opcional:
  `scripts/export-vademecum-blob-samples.ps1`
- Salida local sugerida: `samples/vademecum-blobs/`

El auditor formal no exporta blobs completos. El exportador binario anterior
solo debe usarse como una fase separada y autorizada cuando sea necesario
analizar muestras locales. Ambos usan autenticacion integrada y consultas
`SELECT`, y no modifican la base.

Ejemplo:

```powershell
.\scripts\export-vademecum-blob-samples.ps1 `
  -ServerInstance ".\SQLEXPRESS" `
  -Database "NEPTUNO" `
  -Top 5 `
  -OutputDir ".\samples\vademecum-blobs"
```

Controles:

- `Top` acepta de `1` a `50`.
- Usa autenticacion integrada de Windows.
- Declara `ApplicationIntent=ReadOnly`.
- Exporta como maximo `Top` cabeceras y `Top` contenidos.
- Genera `metadata.csv` con identificadores, nombre, cantidad de bytes y primeros 32 bytes en hexadecimal.
- No intenta decodificar contenido.
- No incluye ni solicita usuario, password o API key.
- La carpeta y extensiones generadas estan ignoradas por Git.
