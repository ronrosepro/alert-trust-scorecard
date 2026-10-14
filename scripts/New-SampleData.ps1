<#
.SYNOPSIS
  Generates SYNTHETIC alert, ticket, and owner CSVs for a 25-office fleet over 30 days.
  Deterministic (seeded) so the demo report is reproducible. No real data.
.EXAMPLE
  ./scripts/New-SampleData.ps1 -OutputDirectory ./samples
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '..' 'samples'),
    [int] $Seed = 42,
    [int] $Sites = 25,
    [int] $Days = 30
)
$ErrorActionPreference = 'Stop'
$rng = [System.Random]::new($Seed)
function Rnd([double] $min, [double] $max) { $min + $rng.NextDouble() * ($max - $min) }
function Chance([double] $p) { $rng.NextDouble() -lt $p }

# Rule profiles: monthly fires per site, chance someone acts, chance it flaps, owner (empty = none)
$profiles = @(
    @{ Rule = 'WAN link down';                          Sev = 'Sev1'; Rate = 1.0; Act = 0.90; Flap = 0.05; Owner = 'Network Ops' }
    @{ Rule = 'Server heartbeat missing';               Sev = 'Sev1'; Rate = 1.0; Act = 0.85; Flap = 0.05; Owner = 'Foundational Platforms' }
    @{ Rule = 'Disk free below 10 percent';             Sev = 'Sev2'; Rate = 1.5; Act = 0.70; Flap = 0.05; Owner = 'Foundational Platforms' }
    @{ Rule = 'Service stopped: practice management';   Sev = 'Sev2'; Rate = 2.0; Act = 0.58; Flap = 0.35; Owner = 'Foundational Platforms' }
    @{ Rule = 'Backup job failed';                      Sev = 'Sev2'; Rate = 1.0; Act = 0.65; Flap = 0.05; Owner = '' }
    @{ Rule = 'Printer offline';                        Sev = 'Sev4'; Rate = 3.0; Act = 0.18; Flap = 0.10; Owner = 'Desktop Support' }
    @{ Rule = 'CPU above 90 percent';                   Sev = 'Sev3'; Rate = 6.0; Act = 0.04; Flap = 0.45; Owner = 'Foundational Platforms' }
    @{ Rule = 'Interface utilization above 80 percent'; Sev = 'Sev3'; Rate = 4.0; Act = 0.03; Flap = 0.30; Owner = 'Network Ops' }
)
$fixes = 'Fixed', 'Restarted service', 'Replaced hardware', 'Escalated to vendor', 'Freed disk space'
$noFix = 'No Action', 'False Positive', 'Auto-Resolved'
$start = [datetime]::new(2026, 9, 1, 0, 0, 0, [DateTimeKind]::Utc)

$alerts = [System.Collections.Generic.List[object]]::new()
$tickets = [System.Collections.Generic.List[object]]::new()
$aid = 1000; $tid = 5000

function Add-Alert($rule, $sev, $site, $device, $raised, $act, [switch] $NoTicket) {
    $script:aid++
    $ticketId = ''
    $wantTicket = -not $NoTicket -and ($act -or (Chance ($(if ($sev -in 'Sev1', 'Sev2') { 0.9 } else { 0.35 }))))
    if ($act) { $cleared = $raised.AddMinutes((Rnd 30 600)) } else { $cleared = $raised.AddMinutes((Rnd 1 20)) }
    if ($wantTicket) {
        $script:tid++
        $ticketId = "INC$script:tid"
        $openDelay = switch ($sev) { 'Sev1' { Rnd 2 8 } 'Sev2' { Rnd 5 30 } default { Rnd 15 120 } }
        $resolveAt = if ($act) { $cleared.AddMinutes((Rnd 5 30)) } else { $raised.AddMinutes($openDelay + (Rnd 10 90)) }
        $tickets.Add([pscustomobject]@{
                TicketId    = $ticketId
                OpenedUtc   = $raised.AddMinutes($openDelay).ToString('o')
                ResolvedUtc = $resolveAt.ToString('o')
                Resolution  = if ($act) { $fixes[$rng.Next($fixes.Count)] } else { $noFix[$rng.Next($noFix.Count)] }
            })
    }
    $alerts.Add([pscustomobject]@{
            AlertId = "A$script:aid"; Rule = $rule; Site = $site; Device = $device; Severity = $sev
            RaisedUtc = $raised.ToString('o'); ClearedUtc = $cleared.ToString('o'); TicketId = $ticketId
        })
    $cleared
}

for ($s = 1; $s -le $Sites; $s++) {
    $site = 'Office-{0:D4}' -f (100 + $s)
    foreach ($p in $profiles) {
        $count = [math]::Max(0, [int][math]::Round((Rnd ($p.Rate * 0.5) ($p.Rate * 1.5)) * $Days / 30))
        for ($i = 0; $i -lt $count; $i++) {
            $device = switch -Wildcard ($p.Rule) {
                'WAN*' { "$site-fw01" } 'Interface*' { "$site-sw0$($rng.Next(1,3))" } 'Printer*' { "$site-prn0$($rng.Next(1,4))" }
                default { "$site-srv01" }
            }
            $raised = $start.AddMinutes((Rnd 0 ($Days * 1440)))
            $act = Chance $p.Act
            $cleared = Add-Alert $p.Rule $p.Sev $site $device $raised $act

            # A WAN outage cascades: the server and printers at that office go dark within minutes.
            if ($p.Rule -eq 'WAN link down') {
                $null = Add-Alert 'Server heartbeat missing' 'Sev1' $site "$site-srv01" $raised.AddMinutes((Rnd 1 3)) $false -NoTicket
                $null = Add-Alert 'Printer offline' 'Sev4' $site "$site-prn01" $raised.AddMinutes((Rnd 1 4)) $false -NoTicket
            }
            # Flapping: the same device fires again shortly after clearing.
            if (Chance $p.Flap) {
                $null = Add-Alert $p.Rule $p.Sev $site $device $cleared.AddMinutes((Rnd 3 25)) $false
            }
        }
    }
}

$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$alerts | Sort-Object RaisedUtc | Export-Csv (Join-Path $OutputDirectory 'alerts.csv') -NoTypeInformation
$tickets | Export-Csv (Join-Path $OutputDirectory 'tickets.csv') -NoTypeInformation
$profiles | Where-Object { $_.Owner } | ForEach-Object { [pscustomobject]@{ Rule = $_.Rule; Owner = $_.Owner } } |
    Export-Csv (Join-Path $OutputDirectory 'owners.csv') -NoTypeInformation
"Wrote $($alerts.Count) alerts and $($tickets.Count) tickets for $Sites sites to $OutputDirectory"
