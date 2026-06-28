# NEPTUNO Local Installation Audit Runbook

## Objetivo y límite operativo

Este paquete inventaría de forma read-only y sanitizada una instalación local
de NEPTUNO para identificar metadatos, archivos candidatos, referencias de
texto y pistas acotadas en binarios. Se ejecuta manualmente en la PC farmacia,
donde está la instalación real.

Codex creó y validó estáticamente el script desde la PC casa. Codex no tiene
acceso a NEPTUNO y no ejecutó el script contra una instalación real.

El audit no modifica bases de datos, no envía datos a Vidalinkco y no intenta
decodificar, desproteger ni evadir licencias, cifrado o controles del proveedor.

## Contrato del script

```text
-InstallPath       obligatorio; directorio raíz de la instalación de NEPTUNO
-OutputDirectory   obligatorio; directorio de salida fuera de InstallPath
```

El script rechaza una salida igual o contenida dentro de `InstallPath`. No usa
archivos temporales y solo crea o sobrescribe estos archivos dentro de
`OutputDirectory`:

- `install-tree.csv`: árbol con ruta relativa, extensión, tamaño, fecha y tipo.
- `candidate-files.csv`: metadatos de extensiones candidatas; para `.exe` y
  `.dll` agrega SHA-256, sin copiar su contenido.
- `keyword-search.txt`: coincidencias legibles con línea, keyword y fragmento
  sanitizado de hasta 160 caracteres.
- `binary-keyword-hints.csv`: solo keywords visibles y SHA-256 de `.exe`/`.dll`;
  no guarda strings completas.
- `sql-modules-vademecum-audit.sql`: consultas `SELECT` read-only para revisar
  metadatos de módulos, objetos, tablas, vistas y columnas en SQL Server.

Los directorios de tipo junction/symlink se inventarían pero no se recorren,
para evitar salir accidentalmente del árbol indicado.

## Qué no se copia ni se comparte

El audit no copia `.exe`, `.dll`, bases de datos, reportes, licencias ni archivos
propietarios completos. No extrae claves, seriales, tokens, usuarios,
contraseñas o servidores desde archivos. Los fragmentos de texto redactan
patrones sensibles antes de guardarse.

Las rutas relativas y demás metadatos también pueden ser información operativa.
No comparta binarios, secretos ni los resultados sin revisión y autorización.
No agregue `exports/` a Git.

## Ejecución futura en la PC farmacia

Desde la raíz del repositorio, abra PowerShell y ejecute:

```powershell
.\scripts\audit-neptuno-install.ps1 `
  -InstallPath "C:\RUTA\NEPTUNO" `
  -OutputDirectory ".\exports\neptuno-install-audit"
```

Si la política local bloquea scripts, habilítelos únicamente para el proceso
actual, según la política autorizada de la farmacia:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## Salida esperada

```text
NEPTUNO installation audit completed (read-only source scan).
Entries inventoried: 1240
Candidate files: 87
Sanitized text matches: 19
Binaries with keyword hints: 3
Audit output: C:\...\exports\neptuno-install-audit
Do not commit, upload or share generated evidence without authorized review.
```

Los conteos son ilustrativos. Una salida válida contiene siempre los cinco
archivos, aunque alguno tenga únicamente encabezados por no existir matches.

## Auditoría SQL opcional y separada

`sql-modules-vademecum-audit.sql` se genera como evidencia para una ejecución
manual posterior contra la base real de NEPTUNO. Contiene únicamente consultas
`SELECT`; el script PowerShell no abre conexiones SQL ni lo ejecuta.

Antes de ejecutar el SQL, confirme una conexión con permisos de solo lectura.
No agregue credenciales al archivo ni comparta resultados sin sanitizarlos.

## Próximos pasos

1. Revisar localmente los cinco artefactos y confirmar que no contienen datos
   que no deban salir de la PC farmacia.
2. Mantener los resultados en `exports/neptuno-install-audit`, ya ignorado por
   Git.
3. Ejecutar opcionalmente el SQL con una cuenta read-only.
4. Analizar solo metadatos y pistas sanitizadas antes de proponer cualquier
   cambio del agente o contrato de sincronización.
5. Eliminar la salida local cuando deje de ser necesaria conforme a la política
   operativa aplicable.

## Riesgos y controles

- Archivos bloqueados o sin permiso detienen el audit para no producir una
  evidencia incompleta presentada como exitosa.
- Los hashes implican lectura completa del binario, pero nunca copia o exporta
  sus bytes.
- Los formatos de reporte binarios se omiten de la búsqueda textual cuando la
  muestra no parece texto legible.
- La sanitización reduce exposición accidental, pero la revisión humana sigue
  siendo obligatoria antes de compartir resultados.

## Resumen ADN

- Alcance: herramienta local, read-only y sanitizada para la PC farmacia.
- Contratos de sincronización, APIs, DTOs, base de datos y publicación no cambian.
- No se crea un flujo paralelo ni se conecta con Vidalinkco.
- La salida es evidencia operativa local y no una nueva fuente de verdad.
- No se habilita extracción de binarios, licencias, secretos o contenido médico.
