# IPanchor-
IPanchor es un software de configuración de red compatible con múltiples sistemas operativos. Resulta muy útil al configurar un servidor por primera vez.
# IPanchor 1.0

|COMAND|

sh ipanchor.sh selftest
powershell -ExecutionPolicy Bypass -File .\ipanchor.ps1


Asistente de terminal para fijar la red de un servidor nuevo (Linux, macOS o Windows). La configuración **se vuelve a aplicar en cada arranque**.

Detecta el sistema solo y lo muestra en la pantalla de bienvenida (por ejemplo `Ubuntu 24.04.1 LTS`, `macOS 14.5` o `Microsoft Windows Server 2022 Standard`). Hay dos ficheros porque Windows no ejecuta scripts `sh`:

| Sistema | Fichero |
|---|---|
| Linux (Ubuntu, Debian, RHEL/Fedora, Alpine, Arch…) y macOS | `ipanchor.sh` |
| Windows Server | `ipanchor.ps1` |

## Descargar y ejecutar

**Linux y macOS**:

```bash
curl -fsSLO https://raw.githubusercontent.com/TU_USUARIO/ipanchor/main/ipanchor.sh
sh ipanchor.sh
```

Sin curl: `wget https://raw.githubusercontent.com/TU_USUARIO/ipanchor/main/ipanchor.sh`

**Windows Server**:

```powershell
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
irm https://raw.githubusercontent.com/TU_USUARIO/ipanchor/main/ipanchor.ps1 -OutFile ipanchor.ps1
.\ipanchor.ps1
```

No hace falta arrancarlo con permisos: se eleva solo (pide la contraseña de `sudo`, o el aviso de Windows). Si PowerShell se queja de la directiva de ejecución: `powershell -ExecutionPolicy Bypass -File .\ipanchor.ps1`.

Sin red todavía en el servidor, lleva el fichero en un USB y ejecútalo desde ahí (`sh /mnt/ipanchor.sh`): se copia solo a `/usr/local/sbin/ipanchor` para el arranque, así que luego puedes retirar el USB.

Descárgalo siempre como fichero: con `curl | sh` o `irm | iex` se niega a arrancar, porque la tarea de arranque necesita el fichero.

## Pantallas

1. **Menú**
   - `set virtual`: crea una red NAT virtual con la IP que elijas. El servidor tiene siempre esa IP, esté en la red física que esté (la tarjeta física sigue con DHCP).
   - `set on local network`: pone una IP fija en la tarjeta de la red local.
   - `Reset config`: deshace lo que haya puesto IPanchor y vuelve a DHCP.
2. **Net config**: cada campo propone el valor actual y con Enter lo aceptas. MASK es la máscara de la red actual (o `255.255.255.0` en la virtual), DNS en blanco usa el gateway y DNS2 es `8.8.8.8` por defecto. También puedes pegar la línea guardada: `IP MASCARA GATEWAY DNS DNS2` (un `-` deja el valor por defecto).
3. **Disable one time only**: `y` la guarda para siempre y `n` la deja solo hasta el próximo reinicio, cuando vuelve la configuración anterior.
4. **Save config on desktop**: guarda `ipanchor-config.txt` con la línea para pegar en otro servidor.
5. **Download all the certifications**: actualiza los certificados raíz y dice cuántos hay.
   - **Linux**: instala `ca-certificates` con apt, dnf, yum, zypper, apk o pacman (en Ubuntu, apt espera a que termine `unattended-upgrades`).
   - **macOS**: los certificados raíz vienen dentro del sistema y se actualizan con Actualización de software, así que IPanchor solo comprueba cuántos hay.
   - **Windows**: instala las raíces de Windows Update una a una. Si alguna falla sale `failed: <error> <certificado>` y el resto se instala igual.

Antes de aplicar comprueba que nadie más use la IP (ping y ARP). Después comprueba que el gateway responde. Si algo falla, muestra `failed: ...`, **restaura la configuración anterior** y vuelve al menú.

## Qué toca en cada sistema

| | Linux | macOS | Windows |
|---|---|---|---|
| Estado | `/etc/ipanchor/` | `/etc/ipanchor/` | `C:\ProgramData\IPanchor\` |
| Arranque | `ipanchor.service` (systemd), `/etc/local.d` (OpenRC) o `rc.local` | LaunchDaemon `com.ipanchor.boot` | Tarea programada `IPanchor` (SYSTEM) |
| Red local | Ver lista de abajo | `networksetup` (servicio de la tarjeta) | `New-NetIPAddress` y `Set-DnsClientServerAddress` |
| Red virtual | Bridge `ipanchor0` con NAT de nftables/iptables | Bridge `bridge77` con NAT de pf | Switch interno de Hyper-V `IPanchor` con `New-NetNat` |

Red local en Linux, según lo que gestione la tarjeta:

- **Ubuntu Server** (netplan con systemd-networkd): `/etc/systemd/network/09-ipanchor.network`. Tiene prioridad sobre lo que genera netplan y no toca tus YAML de `/etc/netplan`, así que también funciona si Ubuntu se instaló con IP fija.
- **NetworkManager** (RHEL, Fedora, escritorios): perfil `ipanchor`, clonado del perfil activo.
- **ifupdown** (Debian, Alpine): `/etc/network/interfaces`, con copia de seguridad.
- Si no hay ninguno de los anteriores, usa `ip` directamente.

En cada arranque vuelve a aplicar la configuración guardada. Si no hay ninguna guardada, vuelve a DHCP y quita el servicio.

## Notas

- Si estás conectado por SSH o RDP a la IP que cambias, se corta la conexión: vuelve a entrar por la IP nueva. El cambio se completa igualmente.
- `set virtual` en Windows necesita Hyper-V: `Install-WindowsFeature Hyper-V -IncludeManagementTools -Restart`.
- Solo IPv4.
- Autocomprobación: `sh ipanchor.sh selftest` o `powershell -File ipanchor.ps1 -SelfTest`.
