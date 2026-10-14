#Requires -Version 7.2
<#
  AlertTrust: answers one question about a monitoring tool. Can the team trust it?

  An alert is trusted when it fires for something real, someone owns it, and someone acts on it.
  This module scores every alert rule against that standard and produces a report:

    Keep          Fires for real problems and people act on it
    Tune          Useful but noisy (low action rate or flapping)
    Retire        Fires often, almost nobody acts on it
    Assign owner  No named owner, so nobody is accountable for it

  Tool-agnostic by design: it reads CSV exports, and config/column-map.json maps your
  export's column names onto the fields below.
#>

Set-StrictMode -Version Latest

$script:DefaultNoAction = @('No Action', 'False Positive', 'Duplicate', 'Auto-Resolved', 'Cleared On Its Own')

function ConvertTo-UtcDate {
    param([AllowNull()] [AllowEmptyString()] [string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
}

function Get-Median {
    param([double[]] $Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $mid = [math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return [math]::Round($sorted[$mid], 1) }
    [math]::Round(($sorted[$mid - 1] + $sorted[$mid]) / 2, 1)
}

function Get-Percent {
    param([double] $Part, [double] $Whole)
    if ($Whole -le 0) { return 0 }
    [math]::Round($Part / $Whole * 100, 1)
}

function Import-AlertTrustData {
    <#
    .SYNOPSIS
      Loads alert, ticket, and owner CSV exports and normalizes them using a column map.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $AlertPath,
        [string] $TicketPath,
        [string] $OwnerPath,
        [string] $ColumnMapPath
    )

    $map = if ($ColumnMapPath) { Get-Content -Raw $ColumnMapPath | ConvertFrom-Json -AsHashtable } else { $null }
    function Get-Col($row, $section, $field) {
        $name = if ($map -and $map[$section] -and $map[$section][$field]) { $map[$section][$field] } else { $field }
        $prop = $row.PSObject.Properties[$name]
        if ($prop) { $prop.Value } else { $null }
    }

    $alerts = foreach ($r in Import-Csv -Path $AlertPath) {
        [pscustomobject]@{
            AlertId    = Get-Col $r 'alerts' 'AlertId'
            Rule       = Get-Col $r 'alerts' 'Rule'
            Site       = Get-Col $r 'alerts' 'Site'
            Device     = Get-Col $r 'alerts' 'Device'
            Severity   = Get-Col $r 'alerts' 'Severity'
            RaisedUtc  = ConvertTo-UtcDate (Get-Col $r 'alerts' 'RaisedUtc')
            ClearedUtc = ConvertTo-UtcDate (Get-Col $r 'alerts' 'ClearedUtc')
            TicketId   = Get-Col $r 'alerts' 'TicketId'
        }
    }

    $tickets = @{}
    if ($TicketPath) {
        foreach ($r in Import-Csv -Path $TicketPath) {
            $id = Get-Col $r 'tickets' 'TicketId'
            $tickets[$id] = [pscustomobject]@{
                TicketId    = $id
                OpenedUtc   = ConvertTo-UtcDate (Get-Col $r 'tickets' 'OpenedUtc')
                ResolvedUtc = ConvertTo-UtcDate (Get-Col $r 'tickets' 'ResolvedUtc')
                Resolution  = Get-Col $r 'tickets' 'Resolution'
            }
        }
    }

    $owners = @{}
    if ($OwnerPath) {
        foreach ($r in Import-Csv -Path $OwnerPath) {
            $rule = Get-Col $r 'owners' 'Rule'
            $owner = Get-Col $r 'owners' 'Owner'
            if ($rule -and $owner) { $owners[$rule] = $owner }
        }
    }

    $noAction = if ($map -and $map['noActionResolutions']) { [string[]] $map['noActionResolutions'] } else { $script:DefaultNoAction }

    [pscustomobject]@{
        Alerts             = @($alerts)
        Tickets            = $tickets
        Owners             = $owners
        NoActionResolution = $noAction
    }
}

function Test-AlertActionable {
    param($Alert, [hashtable] $Ticket, [string[]] $NoActionResolution)
    if ([string]::IsNullOrWhiteSpace($Alert.TicketId)) { return $false }
    if (-not $Ticket.ContainsKey($Alert.TicketId)) { return $false }
    $Ticket[$Alert.TicketId].Resolution -notin $NoActionResolution
}

function Get-AlertRuleScore {
    <#
    .SYNOPSIS
      Scores each alert rule and assigns a verdict: Retire, Assign owner, Tune, or Keep.
    .DESCRIPTION
      Action rate   = alerts whose ticket was resolved with a real action / all alerts
      Flap rate     = alerts that re-fired on the same device within FlapWindowMinutes of clearing
      Short-lived   = alerts that cleared in under 5 minutes without a ticket
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Alert,
        [hashtable] $Ticket = @{},
        [hashtable] $Owner = @{},
        [string[]] $NoActionResolution = $script:DefaultNoAction,
        [int] $FlapWindowMinutes = 30,
        [int] $MinFires = 10,
        [double] $RetireBelowPercent = 10,
        [double] $TuneBelowPercent = 50,
        [double] $TuneFlapAbovePercent = 20
    )

    $rank = @{ 'Retire' = 0; 'Assign owner' = 1; 'Tune' = 2; 'Keep' = 3 }

    $rows = foreach ($group in ($Alert | Group-Object Rule)) {
        $items = @($group.Group)
        $fires = $items.Count
        $actionable = @($items | Where-Object { Test-AlertActionable $_ $Ticket $NoActionResolution }).Count

        $flaps = 0
        foreach ($dev in ($items | Group-Object Device)) {
            $ordered = @($dev.Group | Sort-Object RaisedUtc)
            for ($i = 1; $i -lt $ordered.Count; $i++) {
                $prevClear = $ordered[$i - 1].ClearedUtc
                if ($prevClear -and ($ordered[$i].RaisedUtc - $prevClear).TotalMinutes -le $FlapWindowMinutes) { $flaps++ }
            }
        }

        $shortLived = @($items | Where-Object {
                $_.ClearedUtc -and [string]::IsNullOrWhiteSpace($_.TicketId) -and
                ($_.ClearedUtc - $_.RaisedUtc).TotalMinutes -lt 5
            }).Count

        $actionRate = Get-Percent $actionable $fires
        $flapRate = Get-Percent $flaps $fires
        $ruleOwner = if ($Owner.ContainsKey($group.Name)) { $Owner[$group.Name] } else { $null }

        $verdict, $reason =
        if ($fires -ge $MinFires -and $actionRate -lt $RetireBelowPercent) {
            'Retire', "Fired $fires times; acted on $actionRate%"
        }
        elseif (-not $ruleOwner) {
            'Assign owner', 'No accountable owner'
        }
        elseif ($actionRate -lt $TuneBelowPercent) {
            'Tune', "Only $actionRate% led to action"
        }
        elseif ($flapRate -gt $TuneFlapAbovePercent) {
            'Tune', "Flaps on $flapRate% of fires"
        }
        else {
            'Keep', 'Fires for real problems'
        }

        [pscustomobject]@{
            Rule            = $group.Name
            Severity        = ($items | Group-Object Severity | Sort-Object Count -Descending | Select-Object -First 1).Name
            Fires           = $fires
            Actionable      = $actionable
            ActionRatePct   = $actionRate
            FlapRatePct     = $flapRate
            ShortLived      = $shortLived
            Owner           = $ruleOwner
            Verdict         = $verdict
            Reason          = $reason
            VerdictRank     = $rank[$verdict]
        }
    }

    @($rows | Sort-Object VerdictRank, @{ Expression = 'Fires'; Descending = $true } |
            Select-Object -ExcludeProperty VerdictRank)
}

function Get-SiteCorrelation {
    <#
    .SYNOPSIS
      Groups alerts at the same site into events when they fire within WindowMinutes
      of each other. One WAN outage that trips ten rules becomes one event.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Alert,
        [int] $WindowMinutes = 5
    )

    $sites = foreach ($site in ($Alert | Group-Object Site)) {
        $ordered = @($site.Group | Sort-Object RaisedUtc)
        $events = 0; $burst = 0; $largest = 0; $last = $null
        foreach ($a in $ordered) {
            if ($null -eq $last -or ($a.RaisedUtc - $last).TotalMinutes -gt $WindowMinutes) {
                $events++
                $burst = 0
            }
            $burst++
            if ($burst -gt $largest) { $largest = $burst }
            $last = $a.RaisedUtc
        }
        [pscustomobject]@{
            Site         = $site.Name
            Alerts       = $ordered.Count
            Events       = $events
            LargestBurst = $largest
        }
    }

    $totalAlerts = ($sites | Measure-Object Alerts -Sum).Sum
    $totalEvents = ($sites | Measure-Object Events -Sum).Sum

    [pscustomobject]@{
        Sites   = @(@($sites) | Sort-Object Alerts -Descending)
        Summary = [pscustomobject]@{
            Alerts       = [int] $totalAlerts
            Events       = [int] $totalEvents
            ReductionPct = Get-Percent ($totalAlerts - $totalEvents) $totalAlerts
        }
    }
}

function Get-ResponseMetric {
    <#
    .SYNOPSIS
      Median time to detect (alert raised to ticket opened) and time to resolve
      (alert raised to ticket resolved), by severity and overall, in minutes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Alert,
        [Parameter(Mandatory)] [hashtable] $Ticket
    )

    $joined = foreach ($a in $Alert) {
        if ([string]::IsNullOrWhiteSpace($a.TicketId) -or -not $Ticket.ContainsKey($a.TicketId)) { continue }
        $t = $Ticket[$a.TicketId]
        [pscustomobject]@{
            Severity = $a.Severity
            Mttd     = if ($t.OpenedUtc) { ($t.OpenedUtc - $a.RaisedUtc).TotalMinutes } else { $null }
            Mttr     = if ($t.ResolvedUtc) { ($t.ResolvedUtc - $a.RaisedUtc).TotalMinutes } else { $null }
        }
    }
    $joined = @($joined)

    $bySeverity = foreach ($g in ($joined | Group-Object Severity | Sort-Object Name)) {
        [pscustomobject]@{
            Severity      = $g.Name
            Tickets       = $g.Count
            MedianMttdMin = Get-Median @($g.Group.Mttd | Where-Object { $null -ne $_ })
            MedianMttrMin = Get-Median @($g.Group.Mttr | Where-Object { $null -ne $_ })
        }
    }

    [pscustomobject]@{
        BySeverity = @($bySeverity)
        Overall    = [pscustomobject]@{
            Tickets       = $joined.Count
            MedianMttdMin = Get-Median @($joined.Mttd | Where-Object { $null -ne $_ })
            MedianMttrMin = Get-Median @($joined.Mttr | Where-Object { $null -ne $_ })
        }
    }
}

function Get-TrustProjection {
    <#
    .SYNOPSIS
      What acting on the verdicts would do: alerts removed by retiring noisy rules,
      and the trust score of what is left.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Rule
    )
    $total = ($Rule | Measure-Object Fires -Sum).Sum
    $actionable = ($Rule | Measure-Object Actionable -Sum).Sum
    $retired = @($Rule | Where-Object Verdict -eq 'Retire')
    $retiredFires = if ($retired.Count) { ($retired | Measure-Object Fires -Sum).Sum } else { 0 }
    $retiredActionable = if ($retired.Count) { ($retired | Measure-Object Actionable -Sum).Sum } else { 0 }
    [pscustomobject]@{
        CurrentTrustPct   = Get-Percent $actionable $total
        AlertsRemoved     = [int] $retiredFires
        AlertsRemovedPct  = Get-Percent $retiredFires $total
        ProjectedTrustPct = Get-Percent ($actionable - $retiredActionable) ($total - $retiredFires)
    }
}

function ConvertTo-HtmlSafe {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return '' }
    [System.Net.WebUtility]::HtmlEncode([string] $Value)
}

function Export-AlertTrustReport {
    <#
    .SYNOPSIS
      Writes a self-contained HTML report (no external assets) for the scorecard result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] [string] $Path
    )

    $h = { param($v) ConvertTo-HtmlSafe $v }
    $badge = @{ 'Retire' = 'retire'; 'Assign owner' = 'owner'; 'Tune' = 'tune'; 'Keep' = 'keep' }

    $ruleRows = ($Result.Rules | ForEach-Object {
            "<tr><td>$(& $h $_.Rule)</td><td>$(& $h $_.Severity)</td><td class='n'>$($_.Fires)</td><td class='n'>$($_.ActionRatePct)%</td><td class='n'>$($_.FlapRatePct)%</td><td>$(if ($_.Owner) { & $h $_.Owner } else { '<em>none</em>' })</td><td class='v'><span class='b $($badge[$_.Verdict])'>$(& $h $_.Verdict)</span></td><td class='w'>$(& $h $_.Reason)</td></tr>"
        }) -join "`n"

    $siteRows = ($Result.Correlation.Sites | Select-Object -First 10 | ForEach-Object {
            "<tr><td>$(& $h $_.Site)</td><td class='n'>$($_.Alerts)</td><td class='n'>$($_.Events)</td><td class='n'>$($_.LargestBurst)</td></tr>"
        }) -join "`n"

    $sevRows = ($Result.Response.BySeverity | ForEach-Object {
            "<tr><td>$(& $h $_.Severity)</td><td class='n'>$($_.Tickets)</td><td class='n'>$($_.MedianMttdMin)</td><td class='n'>$($_.MedianMttrMin)</td></tr>"
        }) -join "`n"

    $counts = $Result.Rules | Group-Object Verdict -AsHashTable -AsString
    $n = { param($k) if ($counts -and $counts.ContainsKey($k)) { $counts[$k].Count } else { 0 } }

    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Alert Trust Scorecard</title>
<style>
:root{--bg:#f7f7f5;--card:#fff;--ink:#1f2328;--muted:#5b636d;--line:#e3e3df;
--keep:#1f7a4d;--keepbg:#e3f3ea;--tune:#8a5a00;--tunebg:#fbf0d9;--retire:#a1262b;--retirebg:#f9e1e1;--owner:#3b4cb8;--ownerbg:#e5e8fb;color-scheme:light}
@media (prefers-color-scheme:dark){:root{--bg:#16181b;--card:#1f2226;--ink:#e8e9eb;--muted:#a3a9b0;--line:#33373c;
--keep:#7fd1a5;--keepbg:#173828;--tune:#f0c26b;--tunebg:#3a2e14;--retire:#f19a9d;--retirebg:#3d1b1c;--owner:#a9b4ff;--ownerbg:#22284d;color-scheme:dark}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
main{max-width:1100px;margin:0 auto;padding:32px 20px}h1{margin:0 0 4px;font-size:26px}h2{margin:32px 0 10px;font-size:18px}
.sub{color:var(--muted);margin:0 0 24px}.kpis{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.k{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px}.k.hi{border-color:var(--keep);background:var(--keepbg)}.k.hi .v{color:var(--keep)}.k .v{font-size:26px;font-weight:650}.k .l{color:var(--muted);font-size:13px}
.wrap{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%}th,td{padding:9px 12px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}th{white-space:nowrap}td.n,td.v{white-space:nowrap}td.w{min-width:160px}th.n{text-align:right}
th{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}tr:last-child td{border-bottom:0}td.n{text-align:right;font-variant-numeric:tabular-nums}
.b{display:inline-block;padding:2px 9px;border-radius:999px;font-size:12px;font-weight:600}
.keep{color:var(--keep);background:var(--keepbg)}.tune{color:var(--tune);background:var(--tunebg)}.retire{color:var(--retire);background:var(--retirebg)}.owner{color:var(--owner);background:var(--ownerbg)}
footer{color:var(--muted);font-size:12px;margin-top:28px}
</style></head><body><main>
<h1>Alert Trust Scorecard</h1>
<p class="sub">$(& $h $Result.Source) &middot; $($Result.Summary.WindowStart) to $($Result.Summary.WindowEnd) UTC</p>
<div class="kpis">
<div class="k"><div class="v">$($Result.Summary.TrustScorePct)%</div><div class="l">Trust score: alerts that led to action</div></div>
<div class="k hi"><div class="v">$($Result.Projection.ProjectedTrustPct)%</div><div class="l">Trust score after retiring $(& $n 'Retire') noisy rules ($($Result.Projection.AlertsRemoved) of $($Result.Summary.Alerts) alerts gone)</div></div>
<div class="k"><div class="v">$($Result.Correlation.Summary.ReductionPct)%</div><div class="l">Fewer pages if correlated by site ($($Result.Correlation.Summary.Events) events)</div></div>
<div class="k"><div class="v">$($Result.Response.Overall.MedianMttdMin) min</div><div class="l">Median time to detect</div></div>
<div class="k"><div class="v">$($Result.Response.Overall.MedianMttrMin) min</div><div class="l">Median time to resolve</div></div>
</div>
<h2>Rule verdicts: $(& $n 'Retire') retire, $(& $n 'Assign owner') need an owner, $(& $n 'Tune') tune, $(& $n 'Keep') keep</h2>
<div class="wrap"><table><thead><tr><th>Rule</th><th>Sev</th><th class='n'>Fires</th><th class='n'>Action rate</th><th class='n'>Flap rate</th><th>Owner</th><th>Verdict</th><th>Why</th></tr></thead><tbody>
$ruleRows
</tbody></table></div>
<h2>Noisiest sites (top 10)</h2>
<div class="wrap"><table><thead><tr><th>Site</th><th class='n'>Alerts</th><th class='n'>Correlated events</th><th class='n'>Largest burst</th></tr></thead><tbody>
$siteRows
</tbody></table></div>
<h2>Response time by severity (minutes, median)</h2>
<div class="wrap"><table><thead><tr><th>Severity</th><th class='n'>Tickets</th><th class='n'>Detect</th><th class='n'>Resolve</th></tr></thead><tbody>
$sevRows
</tbody></table></div>
<footer>Generated $(Get-Date -AsUTC -Format 'yyyy-MM-dd HH:mm') UTC by alert-trust-scorecard. Thresholds: retire under $($Result.Settings.RetireBelowPercent)% action after $($Result.Settings.MinFires)+ fires; tune under $($Result.Settings.TuneBelowPercent)% action or over $($Result.Settings.TuneFlapAbovePercent)% flapping; correlation window $($Result.Settings.CorrelationWindowMinutes) min.</footer>
</main></body></html>
"@
    Set-Content -Path $Path -Value $html -Encoding utf8
    Get-Item $Path
}

function Invoke-AlertTrustScorecard {
    <#
    .SYNOPSIS
      One command: load exports, score rules, correlate by site, measure response,
      and write report.html plus rule-scores.csv.
    .EXAMPLE
      Invoke-AlertTrustScorecard -AlertPath ./samples/alerts.csv -TicketPath ./samples/tickets.csv `
        -OwnerPath ./samples/owners.csv -OutputDirectory ./out
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $AlertPath,
        [string] $TicketPath,
        [string] $OwnerPath,
        [string] $ColumnMapPath,
        [string] $OutputDirectory = './out',
        [int] $MinFires = 10,
        [double] $RetireBelowPercent = 10,
        [double] $TuneBelowPercent = 50,
        [double] $TuneFlapAbovePercent = 20,
        [int] $FlapWindowMinutes = 30,
        [int] $CorrelationWindowMinutes = 5
    )

    $data = Import-AlertTrustData -AlertPath $AlertPath -TicketPath $TicketPath -OwnerPath $OwnerPath -ColumnMapPath $ColumnMapPath
    if ($data.Alerts.Count -eq 0) { throw "No alerts found in $AlertPath" }

    $rules = @(Get-AlertRuleScore -Alert $data.Alerts -Ticket $data.Tickets -Owner $data.Owners `
        -NoActionResolution $data.NoActionResolution -FlapWindowMinutes $FlapWindowMinutes -MinFires $MinFires `
        -RetireBelowPercent $RetireBelowPercent -TuneBelowPercent $TuneBelowPercent -TuneFlapAbovePercent $TuneFlapAbovePercent)
    $correlation = Get-SiteCorrelation -Alert $data.Alerts -WindowMinutes $CorrelationWindowMinutes
    $response = Get-ResponseMetric -Alert $data.Alerts -Ticket $data.Tickets

    $actionable = ($rules | Measure-Object Actionable -Sum).Sum
    $times = @($data.Alerts.RaisedUtc | Sort-Object)

    $projection = Get-TrustProjection -Rule $rules

    $result = [pscustomobject]@{
        Source      = (Split-Path $AlertPath -Leaf)
        Projection  = $projection
        Summary     = [pscustomobject]@{
            Alerts        = $data.Alerts.Count
            Rules         = $rules.Count
            TrustScorePct = Get-Percent $actionable $data.Alerts.Count
            WindowStart   = $times[0].ToString('yyyy-MM-dd')
            WindowEnd     = $times[-1].ToString('yyyy-MM-dd')
        }
        Rules       = $rules
        Correlation = $correlation
        Response    = $response
        Settings    = [pscustomobject]@{
            MinFires = $MinFires; RetireBelowPercent = $RetireBelowPercent; TuneBelowPercent = $TuneBelowPercent
            TuneFlapAbovePercent = $TuneFlapAbovePercent; FlapWindowMinutes = $FlapWindowMinutes
            CorrelationWindowMinutes = $CorrelationWindowMinutes
        }
    }

    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $rules | Export-Csv -Path (Join-Path $OutputDirectory 'rule-scores.csv') -NoTypeInformation
    $null = Export-AlertTrustReport -Result $result -Path (Join-Path $OutputDirectory 'report.html')
    $result
}
