# NEPTUNO Pharmacy Read-Only Audit Runbook

## Purpose and safety boundary

This pack audits the local pharmacy SQL Server without modifying `NEPTUNO`,
without sending data to Vidalinkco and without exposing credentials.

All PowerShell connections use:

- Windows integrated authentication
- `Integrated Security=True`
- `Encrypt=False`
- `ApplicationIntent=ReadOnly`
- no username or password parameters

The scripts issue metadata and `SELECT` queries only. Generated files are local
audit evidence and must not be committed or shared outside the authorized
review.

## Requirements on the pharmacy PC

- Windows account with read permission on SQL Server.
- SQL Server reachable as `localhost` using the default `MSSQLSERVER` instance.
- Main database: `NEPTUNO`.
- Audit/log database confirmed on the same server: `neptunobitacora`; this pack
  does not query it because the requested product and schema scope is NEPTUNO.
- Windows PowerShell 5.1 or PowerShell 7.
- A local checkout of this repository.

The .NET SDK is not required to run these PowerShell audit scripts. The sync
agent itself targets and builds with .NET 10.

## Open PowerShell

1. Open the repository folder in File Explorer.
2. Click the address bar, type `powershell` and press Enter.
3. Confirm the current directory contains `scripts`, `docs` and
   `Vidalinkco.NeptunoSyncAgent`.

If local policy blocks scripts, allow them only for the current process:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Do not change machine-wide execution policy for this audit.

If PowerShell opens in `C:\WINDOWS\system32`, the default export directory is
still resolved from the repository root: `<repo-root>/exports/local-audit`.
You can also pass an absolute `-OutputDirectory` when the evidence must be
written somewhere else.

## Parameter contract

Product audit:

```text
-Server           string, default localhost
-Database         string, default NEPTUNO
-ProductId        positive integer, default 9102
-VademecumId      optional; defaults to in_producto.id_vademecum
-OutputDirectory  string, default <repo-root>/exports/local-audit
-Export           switch; without it the script prints a console summary only
```

Schema audit:

```text
-Server           string, default localhost
-Database         string, default NEPTUNO
-OutputDirectory  string, default <repo-root>/exports/local-audit
-Export           switch
```

Vademecum audit:

```text
-Server           string, default localhost
-Database         string, default NEPTUNO
-ProductId        positive integer, default 9102
-VademecumId      optional; if omitted it is resolved from ProductId
-OutputDirectory  string, default <repo-root>/exports/local-audit
-Export           switch
```

## Audit product 9102

Console-only:

```powershell
.\scripts\audit-neptuno-product.ps1
```

With local exports:

```powershell
.\scripts\audit-neptuno-product.ps1 `
  -Server "localhost" `
  -Database "NEPTUNO" `
  -ProductId 9102 `
  -VademecumId 1809 `
  -OutputDirectory ".\exports\local-audit" `
  -Export
```

Expected confirmed sample:

- Product: `GEMFIBROZILO COMx600MGx20 ECUA`
- `id_item` / `id_producto`: `9102`
- Vademecum: `1809`, `GEMFIBROZILO`
- Catalog codes: `COM`, `MG10`, `G134`
- Known labels: `COMPRIMIDOS`, `600 MG`, `600 MG`
- Warehouse `1`
- State: `ACT FRANQUICIA`
- Can sell: `S`
- Warehouse enabled: `S`
- Unit stock: `1`
- Fraction stock: `3`

Local product exports:

- `product-summary.json`
- `product-flat-fields.csv`
- `product-stock.csv`
- `product-vademecum-sections.csv`
- `product-extra-tables.txt`

The script audits direct product references in all requested extra tables. If a
table exists but has no direct `id_producto`, `id_item` or
`id_producto_comercial` column, the report marks it as
`no-direct-reference`; use the schema audit to inspect its relationship path.

## Audit the NEPTUNO schema

Console-only:

```powershell
.\scripts\audit-neptuno-schema.ps1
```

With local metadata export:

```powershell
.\scripts\audit-neptuno-schema.ps1 `
  -Server "localhost" `
  -Database "NEPTUNO" `
  -OutputDirectory ".\exports\local-audit" `
  -Export
```

The export is `schema-audit.json`. It includes relevant tables, columns,
foreign keys, catalog previews and table names related to products, medicine,
vademecum, dose, posology, indications, warnings, laboratories, attributes and
messages.

## Audit vademecum 1809

Explicit vademecum:

```powershell
.\scripts\audit-neptuno-vademecum-blob.ps1 `
  -Server "localhost" `
  -Database "NEPTUNO" `
  -ProductId 9102 `
  -VademecumId 1809
```

Resolve it from product 9102 and write local metadata:

```powershell
.\scripts\audit-neptuno-vademecum-blob.ps1 `
  -ProductId 9102 `
  -OutputDirectory ".\exports\local-audit" `
  -Export
```

The script reads only the first 512 bytes of each blob for bounded inspection.
It reports byte count, hex preview, safe printable-ASCII preview, known
signature detection and `pending-reliable-decoding-do-not-publish` status.

It does not export complete blobs and does not present blob bytes as final
medical text.

## Review results

1. Read the console summary first.
2. Keep exports inside `exports/local-audit`.
3. Confirm the product and vademecum identifiers.
4. Review `product-flat-fields.csv` before proposing any mapping.
5. Treat `product-vademecum-sections.csv` as metadata only.
6. Use `schema-audit.json` to resolve missing or indirect relationships.
7. Record uncertain fields as pending human review; do not infer descriptions
   or medical claims.

## Never upload to Git

Do not add:

- `exports/`, `local/` or `private/`
- real CSV, TXT, JSON or database dumps
- `.xlsx`, `.xls`, `.jsonl`, `.dump`, `.bak`
- `appsettings.local.json` or `appsettings.*.local.json`
- `.env` or `.env.*`
- blob samples (`.bin`, `.blob`, `.dat`)

Before committing code or documentation:

```powershell
git status --short --untracked-files=all
git ls-files "*.csv" "*.xlsx" "*.xls" "*.jsonl" "*.dump" "*.bak" "*.bin" "*.blob" "*.dat"
git check-ignore ".\exports\local-audit\product-summary.json"
```

The first command must not show real exports. The second command should return
no tracked audit data. The third command should confirm the export is ignored.

## Troubleshooting

### SQL Server does not respond

- Confirm the SQL Server service for `MSSQLSERVER` is running.
- Keep `-Server "localhost"` for the confirmed default instance.
- If the installed instance differs, pass its real server/instance name.
- Do not add SQL usernames or passwords to scripts or config files.

### Integrated Security permission error

- Run PowerShell as the Windows user authorized for NEPTUNO.
- Ask the database administrator for read-only access.
- Do not work around the error with shared credentials.

### `in_bodega.descripcion` does not exist

This pack does not use that column. It uses `b.nombre` and adds
`b.nombre_largo` or `b.nombre_comercial` only when those columns exist.

### Blob content is not readable

This is the expected current state. The known blobs are not readable as plain
varchar/nvarchar, UTF-8, UTF-16, Windows-1252, gzip, deflate or brotli. Keep
them as opaque data pending a reliable, reproducible decoder and human medical
review.

### An extra table reports `no-direct-reference`

Run the schema audit and inspect its foreign keys and columns. Do not guess a
join or create a parallel mapping.

## Architecture / ADN summary

- Scope: local, read-only audit tooling for the pharmacy PC.
- Public product SSOT remains Vidalinkco `Product`.
- NEPTUNO data remains external/staging/enrichment input.
- No endpoint, sync payload, database schema, SEO or publication behavior is
  changed.
- Vademecum sections are metadata pending reliable decoding.
- Existing sync-agent contracts remain unchanged.
