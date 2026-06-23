# CSV samples

Place local test CSV files here only on your machine.

Suggested local filenames:

- `stock-price-real-smoke.csv`
- `catalog-real-smoke.csv`
- `catalog-real-batch-100-v3.csv`

Real NEPTUNO exports, pharmacy inventory dumps, stock files, price files, catalog exports, and any CSV/TSV files are ignored by git and must not be committed.

Do not include API keys, connection strings, cost fields, margin fields, utility fields, purchase-cost fields, vademecum blobs, images, or long medical texts in sample files.

For the controlled catalog batch 100 flow, generate the CSV from `docs/sql/catalog-real-batch-100-v3.sql`, place it locally at `samples/catalog-real-batch-100-v3.csv`, run dry-run first, and keep the file ignored by Git.
