# IPanchor 1.0 - pins the network config of a Windows server and puts it back on every boot.
# Linux servers: ipanchor.sh
param([switch]$Boot, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$Dir = "$env:ProgramData\IPanchor"
$Cur = "$Dir\current.txt"   # config applied now: MODE|IF|IP|MASK|GW|DNS|DNS2
$Saved = "$Dir\saved.txt"   # config restored on every boot (no file = back to DHCP)
$Self = "$Dir\ipanchor.ps1"
$Sw = 'IPanchor'            # Hyper-V switch + NAT of "set virtual"
$Keys = 'MODE', 'IF', 'IP', 'MASK', 'GW', 'DNS', 'DNS2'
$C = @{}

function Say { $args | ForEach-Object { Write-Host $_ } }
function Fail($m) { Write-Host "failed: $m" -ForegroundColor Red }
function YN($q) { (Read-Host "$q y/n") -match '^[ys]' }
function Field($label, $def) { $v = Read-Host ('{0,-8} [{1}]' -f $label, $def); if ($v) { $v.Trim() } else { $def } }
function Line { ($Keys | ForEach-Object { $C[$_] }) -join '|' }
function Load($file) { $v = (Get-Content $file -Raw).Trim() -split '\|'; for ($i = 0; $i -lt $Keys.Count; $i++) { $C[$Keys[$i]] = $v[$i] } }
function Final { Say '' 'The configuration is set.' '' 'THX for using IPanchor 1.0!!'; exit }

function IsIp($s) { $s -match '^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$' }
function Mask($p) { (0..3 | ForEach-Object { 256 - [math]::Pow(2, 8 - [math]::Min(8, [math]::Max(0, $p - 8 * $_))) }) -join '.' }
function Cidr($m) { 0..32 | Where-Object { (Mask $_) -eq $m } | Select-Object -First 1 }

function NetConfig {
  Say '' 'Net config:' '----------------------'
  $C.IF = '-'; $C.IP = ''; $C.MASK = '255.255.255.0'; $C.GW = '-'; $C.DNS = '-'; $C.DNS2 = '-'
  if ($C.MODE -eq 'local') {
    Say ('Interfaces: ' + ((Get-NetAdapter | Where-Object Status -eq Up).Name -join ', '))
    $r = Get-NetRoute -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    $C.IF = Field IFACE $r.InterfaceAlias
    if (-not $C.IF -or -not (Get-NetAdapter -Name $C.IF -ErrorAction SilentlyContinue)) { Fail "there is no interface '$($C.IF)'"; return $false }
    $a = Get-NetIPAddress -InterfaceAlias $C.IF -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object IPAddress -notlike '169.254.*' | Select-Object -First 1
    if ($a) { $C.IP = $a.IPAddress; $C.MASK = Mask $a.PrefixLength }
    $C.GW = [string](Get-NetRoute -InterfaceAlias $C.IF -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop
    $C.DNS2 = '8.8.8.8'
  }
  $paste = Read-Host 'Paste the saved config (Enter to type it)'
  if ($paste) {
    $v = $paste.Trim() -split '\s+'
    $C.IP = $v[0]; if ($v[1]) { $C.MASK = $v[1] }
    if ($C.MODE -eq 'local') {
      if ($v[2] -and $v[2] -ne '-') { $C.GW = $v[2] }
      $C.DNS = if ($v[3]) { $v[3] } else { '-' }
      if ($v[4] -and $v[4] -ne '-') { $C.DNS2 = $v[4] }
    }
  } else {
    $C.IP = Field IPv4 $C.IP
    $C.MASK = Field MASK $C.MASK
    if ($C.MODE -eq 'local') { $C.GW = Field GATEWAY $C.GW; $C.DNS = Field DNS $C.GW; $C.DNS2 = Field DNS2 $C.DNS2 }
  }
  if ($C.MODE -eq 'local' -and $C.DNS -eq '-') { $C.DNS = $C.GW }   # blank DNS = the gateway
  foreach ($x in $C.IP, $C.GW, $C.DNS, $C.DNS2) { if ($x -ne '-' -and -not (IsIp $x)) { Fail "bad IP '$x'"; return $false } }
  if ($null -eq (Cidr $C.MASK)) { Fail "bad MASK '$($C.MASK)'"; return $false }
  Say '----------------------' "IFACE    $($C.IF)" "IPv4     $($C.IP)" "MASK     $($C.MASK)" "GATEWAY  $($C.GW)" "DNS      $($C.DNS)" "DNS2     $($C.DNS2)"
  (Read-Host '  > Save    > Cancel   [s/c]') -notmatch '^c'
}

function UpLocal {
  $i = $C.IF
  Set-NetIPInterface -InterfaceAlias $i -AddressFamily IPv4 -Dhcp Disabled
  foreach ($s in 'ActiveStore', 'PersistentStore') {   # a leftover gateway in either store blocks New-NetIPAddress
    Remove-NetRoute -InterfaceAlias $i -DestinationPrefix 0.0.0.0/0 -PolicyStore $s -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetIPAddress -InterfaceAlias $i -AddressFamily IPv4 -PolicyStore $s -Confirm:$false -ErrorAction SilentlyContinue
  }
  New-NetIPAddress -InterfaceAlias $i -IPAddress $C.IP -PrefixLength (Cidr $C.MASK) -DefaultGateway $C.GW | Out-Null
  Set-DnsClientServerAddress -InterfaceAlias $i -ServerAddresses ($C.DNS, $C.DNS2 | Select-Object -Unique)
}

function UpVirtual {  # Hyper-V internal switch with the fixed IP + NAT out through whatever uplink the server has
  if (-not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) { throw 'set virtual needs Hyper-V: Install-WindowsFeature Hyper-V -IncludeManagementTools -Restart' }
  if (-not (Get-VMSwitch -Name $Sw -ErrorAction SilentlyContinue)) { New-VMSwitch -Name $Sw -SwitchType Internal | Out-Null }
  $a = "vEthernet ($Sw)"; $p = Cidr $C.MASK
  if (-not (Get-NetIPAddress -InterfaceAlias $a -IPAddress $C.IP -ErrorAction SilentlyContinue)) {
    Remove-NetIPAddress -InterfaceAlias $a -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $a -IPAddress $C.IP -PrefixLength $p | Out-Null
  }
  if (-not (Get-NetNat -Name $Sw -ErrorAction SilentlyContinue)) {
    $ip = ([ipaddress]$C.IP).GetAddressBytes(); $m = ([ipaddress]$C.MASK).GetAddressBytes()
    New-NetNat -Name $Sw -InternalIPInterfaceAddressPrefix ('{0}/{1}' -f ((0..3 | ForEach-Object { $ip[$_] -band $m[$_] }) -join '.'), $p) | Out-Null
  }
}

function Undo {  # take back what $Cur says is applied (local goes back to DHCP)
  if (-not (Test-Path $Cur)) { return }
  $o = (Get-Content $Cur -Raw).Trim() -split '\|'; Remove-Item $Cur
  if ($o[0] -eq 'virtual') {
    Remove-NetNat -Name $Sw -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-Command Remove-VMSwitch -ErrorAction SilentlyContinue) { Remove-VMSwitch -Name $Sw -Force -ErrorAction SilentlyContinue }
    return
  }
  foreach ($s in 'ActiveStore', 'PersistentStore') { Remove-NetRoute -InterfaceAlias $o[1] -DestinationPrefix 0.0.0.0/0 -PolicyStore $s -Confirm:$false -ErrorAction SilentlyContinue }
  netsh interface ipv4 set address $o[1] dhcp | Out-Null
  Set-DnsClientServerAddress -InterfaceAlias $o[1] -ResetServerAddresses -ErrorAction SilentlyContinue
}

function Apply {
  New-Item -ItemType Directory -Force $Dir | Out-Null
  if (Test-Path $Cur) {   # a new local config on the same interface replaces the old one in place
    $old = (Get-Content $Cur -Raw).Trim(); $o = $old -split '\|'
    if (-not (($o[0] -eq 'local' -and $o[1] -eq $C.IF) -or $old -eq (Line))) { Undo }
  }
  Line | Set-Content $Cur -Encoding UTF8
  if ($C.MODE -eq 'local') { UpLocal } else { UpVirtual }
}

function Restore {  # back to the saved config, or to DHCP when nothing is saved
  if (Test-Path $Saved) { Load $Saved; Apply } else { Undo; BootOff }
}

function Neighbor($ip) { Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue | Where-Object { $_.LinkLayerAddress -notmatch '^[0-]*$' } }

function Taken {  # another device already answers on the IP (ping, or ARP when it blocks ping)
  if (Get-NetIPAddress -IPAddress $C.IP -ErrorAction SilentlyContinue) { return $false }
  Remove-NetNeighbor -IPAddress $C.IP -Confirm:$false -ErrorAction SilentlyContinue
  (Test-Connection $C.IP -Count 1 -Quiet) -or [bool](Neighbor $C.IP)
}

function Verify {  # local: the gateway must answer (ping, or at least ARP) within 15 s
  if ($C.MODE -eq 'virtual') { return $true }
  Remove-NetNeighbor -InterfaceAlias $C.IF -Confirm:$false -ErrorAction SilentlyContinue
  for ($t = 0; $t -lt 15; $t++) {
    if ((Test-Connection $C.GW -Count 1 -Quiet) -or (Neighbor $C.GW)) { return $true }
    Start-Sleep 1
  }
  $false
}

function BootOn {  # scheduled task that runs "ipanchor.ps1 -Boot" on every start
  if ($PSCommandPath -ne $Self) { Copy-Item $PSCommandPath $Self -Force }
  $act = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Self`" -Boot"
  $who = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
  $t = New-ScheduledTaskTrigger -AtStartup; $t.Delay = 'PT30S'   # give drivers and Hyper-V time to come up
  Register-ScheduledTask -TaskName IPanchor -Action $act -Trigger $t -Principal $who -Force | Out-Null
}

function BootOff { Unregister-ScheduledTask -TaskName IPanchor -Confirm:$false -ErrorAction SilentlyContinue }

function SaveDesktop {
  $d = [Environment]::GetFolderPath('Desktop'); if (-not $d) { $d = $HOME }
  $f = Join-Path $d 'ipanchor-config.txt'
  Set-Content $f 'IPanchor config - paste this line in "Net config":', "$($C.IP) $($C.MASK) $($C.GW) $($C.DNS) $($C.DNS2)"
  Say "Saved: $f"
}

function Certs {  # root certificates from Windows Update, one by one so a bad one does not stop the rest
  $sst = "$env:TEMP\ipanchor-roots.sst"
  certutil -f -generateSSTFromWU $sst | Out-Null
  if ($LASTEXITCODE) { Fail "certutil could not get the root list from Windows Update (exit $LASTEXITCODE)"; return }
  $all = New-Object Security.Cryptography.X509Certificates.X509Certificate2Collection
  try { $all.Import($sst) } catch { Fail $_.Exception.Message; return }
  $store = New-Object Security.Cryptography.X509Certificates.X509Store 'Root', 'LocalMachine'
  $store.Open('ReadWrite'); $n = 0
  foreach ($cert in $all) { try { $store.Add($cert); $n++ } catch { Fail "$($_.Exception.Message) $($cert.Subject)" } }
  $store.Close(); Say "$n root certificates installed"
}

if ($SelfTest) {
  $ok = (Mask 24) -eq '255.255.255.0' -and (Mask 0) -eq '0.0.0.0' -and (Cidr '255.255.255.255') -eq 32 -and (Cidr '255.255.240.0') -eq 20 -and
    $null -eq (Cidr '255.0.255.0') -and (IsIp '10.0.0.1') -and -not (IsIp '256.1.1.1') -and -not (IsIp '1.2.3') -and -not (IsIp '01.2.3.4')
  if ($ok) { Say 'selftest ok'; exit 0 } else { Say 'selftest FAILED'; exit 1 }
}
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Fail 'run it as Administrator'; exit 1 }
if (-not $PSCommandPath) { Fail 'save it as ipanchor.ps1 and run that file (the boot task needs it)'; exit 1 }
if ($Boot) { try { Restore } catch { Add-Content "$Dir\boot.log" "$(Get-Date -Format s) $_" }; exit }

$SysName = (Get-CimInstance Win32_OperatingSystem).Caption
while ($true) {
  Say '' ' ----------------------' '  Welcome to IPanchor' ' \--------------------/' "  $SysName" '' '  1 > set virtual' '  2 > set on local network' '  3 > Reset config' '  q > quit' ''
  $choice = Read-Host '>'
  if ($choice -eq '1') { $C.MODE = 'virtual' }
  elseif ($choice -eq '2') { $C.MODE = 'local' }
  elseif ($choice -eq '3') {
    if (-not (Test-Path $Cur)) { Say 'IPanchor has nothing applied, nothing to reset.' }
    Undo; Remove-Item $Saved -ErrorAction SilentlyContinue; BootOff; Final
  }
  elseif ($choice -eq 'q') { exit }
  else { continue }
  if (-not (NetConfig)) { continue }
  $keep = YN 'Disable one time only? (y = keep it after reboot, n = only until reboot)'
  if (Taken) { Fail "$($C.IP) is already taken by another device"; continue }
  if ($C.MODE -eq 'local') { Say "If you are connected through $($C.IF) you will be disconnected: log in again at $($C.IP)" }
  Say 'Applying...'
  try { Apply; $ok = Verify; $why = "gateway $($C.GW) does not answer from $($C.IP)" } catch { $ok = $false; $why = $_.Exception.Message }
  if (-not $ok) { Fail "$why, restoring the previous config"; try { Restore } catch { Fail $_.Exception.Message }; continue }
  if ($keep) { Copy-Item $Cur $Saved -Force }
  BootOn
  if (YN 'Save config on desktop') { SaveDesktop }
  if (YN 'Download all the certifications') { Certs }
  Final
}
