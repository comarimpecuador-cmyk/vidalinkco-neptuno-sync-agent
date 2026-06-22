# Vidalinkco NEPTUNO Sync Agent

Agente Windows para preparar la sincronizacion futura entre NEPTUNO SQL Server y Vidalinkco por HTTPS. En esta fase no conecta a SQL Server, no instala Windows Service y solo permite probar heartbeat con modo dry-run o envio real controlado.

## Configuracion

1. Copia `Vidalinkco.NeptunoSyncAgent/appsettings.example.json` como `Vidalinkco.NeptunoSyncAgent/appsettings.local.json`.
2. Edita `appsettings.local.json` localmente.
3. Define `NeptunoSyncAgent:ApiKey` solo en `appsettings.local.json` o variables de entorno. Nunca subas la API key al repositorio.
4. Mantén `DryRun: true` hasta validar el payload.

`appsettings.local.json` esta ignorado por git.

## Ejecutar heartbeat en dry-run

Desde la raiz del repositorio:

```powershell
dotnet run --project .\Vidalinkco.NeptunoSyncAgent -- --heartbeat-once --dry-run
```

Esto imprime el payload y escribe un registro local en `logs/agent.log`. No envia datos a Vidalinkco.

## Ejecutar heartbeat real

Configura `appsettings.local.json` con:

```json
{
  "NeptunoSyncAgent": {
    "VidalinkcoBaseUrl": "https://tu-dominio-vidalinkco.com",
    "ApiKey": "valor-real-solo-local",
    "DryRun": false
  }
}
```

Luego ejecuta:

```powershell
dotnet run --project .\Vidalinkco.NeptunoSyncAgent -- --heartbeat-once
```

El cliente enviara `POST /api/integrations/neptuno/heartbeat` con el header `x-vidalinkco-integration-key`. No imprimas ni pegues la API key en logs, issues o commits.

## Publicar EXE self-contained para Windows

```powershell
dotnet publish .\Vidalinkco.NeptunoSyncAgent -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o .\publish\win-x64
```

Despues de publicar, coloca un `appsettings.local.json` junto al ejecutable si necesitas configuracion real local.

## Estado de esta fase

- Implementado: configuracion tipada, dry-run, cliente HTTPS, heartbeat manual, ciclo worker de heartbeat y logging local basico.
- No implementado todavia: conexion SQL Server real, lectura de tablas NEPTUNO, modo CSV, sincronizacion stock-precio, catalogo y Windows Service.
