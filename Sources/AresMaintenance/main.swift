import Darwin
import EcosystemLocalIPC

// Раздельные executable закрепляют домен: CLI Ареса не обслуживает Афину.
exit(InstalledMaintenanceCommand.run(domain: "ares"))
