<#
Boot the Windows build of the Halo 3 port. Lives next to halo3.exe in the
folder setup-halo3-windows.sh stages (game data in .\game).

  .\play-halo3.cmd [options] [extra runtime flags, e.g. --keybind_y=Q]

  -Name NAME         gamertag; every player needs a different one
  -Live              sign in to the Xbox Live stand-in (slop-box-live); enables matchmaking
  -LiveServer URL    its address (default http://127.0.0.1:36080)
  -Instance N        several instances on one PC: instance N (1..16) uses 127.0.0.<N+1>,
                     gamertag PlayerN and its own saves/caches (instances\N)
  -Zt                system link over ZeroTier: advertise this PC's ZeroTier IPv4 address
  -Ip ADDR           system link using this IPv4 address instead of the default adapter
  -Fullscreen        fullscreen instead of a 1280x800 window
  -Scale N           render at N x N internal resolution
  -Fps               print the guest frame rate every 5 s
  -Mnk               play with mouse and keyboard instead of a controller:
                       WASD move        mouse aim         left click fire
                       right click zoom G grenade         T switch grenades
                       R reload/action  F melee           E equipment
                       1 switch weapon  C crouch          Space jump
                       Tab scoreboard   Enter pause       Shift+arrows D-pad
                     Override single keys with extra flags such as --keybind_y=Q (keys:
                     letters, digits, Space, Tab, Return, LMB, RMB, MMB, Numpad0...)
  -Sensitivity N     mouse speed with -Mnk (0.01..10, default 1)
Anything else is passed to the game unchanged.
#>
param(
  [string]$Name,
  [switch]$Live,
  [string]$LiveServer = "http://127.0.0.1:36080",
  [int]$Instance = 0,
  [switch]$Zt,
  [string]$Ip,
  [switch]$Fullscreen,
  [int]$Scale = 0,
  [switch]$Fps,
  [switch]$Mnk,
  [double]$Sensitivity = 0,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$exe = Join-Path $root "halo3.exe"

$gameArgs = @("--game_data_root=$(Join-Path $root 'game')", "--gpu_plugin=xenos")
if ($Fullscreen) { $gameArgs += "--fullscreen=true" }
else { $gameArgs += @("--fullscreen=false", "--window_width=1280", "--window_height=800") }
if ($Scale -gt 0) { $gameArgs += @("--draw_resolution_scale_x=$Scale", "--draw_resolution_scale_y=$Scale") }
if ($Fps) { $env:AUTOPORT_FPS = "1" }
if ($Live) { $gameArgs += "--live_server=$LiveServer" }
if ($Name) { $gameArgs += "--user_name=$Name" }

if ($Zt) {
  $Ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -like "ZeroTier*" } |
    Select-Object -First 1 -ExpandProperty IPAddress
  if (-not $Ip) { throw "-Zt: no ZeroTier adapter with an IPv4 address (is ZeroTier joined?)" }
  Write-Host "ZeroTier system link address: $Ip"
}

if ($Instance -ne 0) {
  if ($Instance -lt 1 -or $Instance -gt 16) { throw "-Instance must be 1..16" }
  if ($Ip) { throw "-Instance cannot be combined with -Zt/-Ip" }
  $data = Join-Path $root "instances\$Instance"
  New-Item -ItemType Directory -Force -Path $data | Out-Null
  $tag = if ($Name) { $Name } else { "Player$Instance" }
  $gameArgs += @("--net_ip=127.0.0.$($Instance + 1)", "--user_name=$tag",
    "--user_data_root=$data", "--cache_root=$(Join-Path $data 'cache')",
    "--log_file=$(Join-Path $data 'halo3.log')", "--log_max_file_size_mb=200")
} elseif (Get-Process -Name halo3 -ErrorAction SilentlyContinue) {
  throw "halo3 is already running (use -Instance N for several on one PC)"
}
if ($Ip) { $gameArgs += "--net_ip=$Ip" }

if ($Mnk) {
  $mnkArgs = [ordered]@{
    mnk_mode = "true"; mnk_mouse = "true"
    keybind_right_trigger = "LMB"; keybind_rstick_press = "RMB"
    keybind_left_trigger = "G"; keybind_left_shoulder = "T"
    keybind_right_shoulder = "R"; keybind_a = "Space"; keybind_b = "F"
    keybind_x = "E"; keybind_y = "1"; keybind_lstick_press = "C"
    keybind_back = "Tab"; keybind_start = "Return"
  }
  if ($Sensitivity -gt 0) {
    $mnkArgs.mnk_sensitivity = $Sensitivity.ToString([cultureinfo]::InvariantCulture)
  }
  # A flag given more than once is rejected by the runtime, so extra flags
  # replace the layout's value for the same name instead of repeating it.
  $given = @($Extra | ForEach-Object { if ($_ -match '^--([^=]+)=') { $Matches[1] } })
  foreach ($key in $mnkArgs.Keys) {
    if ($given -notcontains $key) { $gameArgs += "--$key=$($mnkArgs[$key])" }
  }
}
if ($Extra) { $gameArgs += $Extra | Where-Object { $_ -ne "--" } }

Set-Location $root
& $exe @gameArgs
