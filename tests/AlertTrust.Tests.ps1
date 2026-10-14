# Unit tests on small hand-built fixtures: every expected number below can be checked by hand.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'AlertTrust' 'AlertTrust.psd1') -Force
    $script:T0 = [datetime]::new(2026, 9, 1, 12, 0, 0, [DateTimeKind]::Utc)

    function New-A([string] $Rule, [string] $Site = 'S1', [string] $Device = 'D1', [int] $At = 0,
                   [int] $Lasts = 60, [string] $Ticket = '', [string] $Sev = 'Sev2') {
        [pscustomobject]@{
            AlertId = [guid]::NewGuid().ToString(); Rule = $Rule; Site = $Site; Device = $Device; Severity = $Sev
            RaisedUtc = $T0.AddMinutes($At); ClearedUtc = $T0.AddMinutes($At + $Lasts); TicketId = $Ticket
        }
    }
    function New-T([string] $Id, [string] $Resolution = 'Fixed', [int] $OpenAt = 5, [int] $ResolveAt = 65) {
        [pscustomobject]@{ TicketId = $Id; OpenedUtc = $T0.AddMinutes($OpenAt); ResolvedUtc = $T0.AddMinutes($ResolveAt); Resolution = $Resolution }
    }
}

Describe 'Get-AlertRuleScore' {
    BeforeAll {
        $alerts = [System.Collections.Generic.List[object]]::new()
        $tickets = @{}
        # Rule "Good": 10 fires, all fixed -> Keep
        for ($i = 0; $i -lt 10; $i++) { $alerts.Add((New-A 'Good' -Device "G$i" -At ($i * 100) -Ticket "TG$i")); $tickets["TG$i"] = New-T "TG$i" }
        # Rule "Noise": 12 fires, tickets closed as No Action -> Retire
        for ($i = 0; $i -lt 12; $i++) { $alerts.Add((New-A 'Noise' -Device "N$i" -At ($i * 100) -Ticket "TN$i")); $tickets["TN$i"] = New-T "TN$i" 'No Action' }
        # Rule "Orphan": 3 fires, fixed, but no owner -> Assign owner
        for ($i = 0; $i -lt 3; $i++) { $alerts.Add((New-A 'Orphan' -Device "O$i" -At ($i * 100) -Ticket "TO$i")); $tickets["TO$i"] = New-T "TO$i" }
        # Rule "Flappy": 4 fires on ONE device, each re-firing 10 min after clearing; 3 fixed -> Tune (flap 75%)
        $alerts.Add((New-A 'Flappy' -Device 'F1' -At 0 -Lasts 20 -Ticket 'TF0')); $tickets['TF0'] = New-T 'TF0'
        $alerts.Add((New-A 'Flappy' -Device 'F1' -At 30 -Lasts 20 -Ticket 'TF1')); $tickets['TF1'] = New-T 'TF1'
        $alerts.Add((New-A 'Flappy' -Device 'F1' -At 60 -Lasts 20 -Ticket 'TF2')); $tickets['TF2'] = New-T 'TF2'
        $alerts.Add((New-A 'Flappy' -Device 'F1' -At 90 -Lasts 20))

        $owners = @{ Good = 'Platforms'; Noise = 'Platforms'; Flappy = 'Platforms' }
        $script:scores = Get-AlertRuleScore -Alert $alerts -Ticket $tickets -Owner $owners
        $script:byRule = @{}; foreach ($s in $scores) { $byRule[$s.Rule] = $s }
    }

    It 'keeps a rule people always act on' {
        $byRule['Good'].Verdict | Should -Be 'Keep'
        $byRule['Good'].ActionRatePct | Should -Be 100
    }
    It 'retires a frequent rule nobody acts on' {
        $byRule['Noise'].Verdict | Should -Be 'Retire'
        $byRule['Noise'].ActionRatePct | Should -Be 0
    }
    It 'flags a rule with no owner' {
        $byRule['Orphan'].Verdict | Should -Be 'Assign owner'
    }
    It 'detects flapping on the same device' {
        $byRule['Flappy'].FlapRatePct | Should -Be 75
        $byRule['Flappy'].Verdict | Should -Be 'Tune'
    }
    It 'sorts the worst verdicts first' {
        $scores[0].Verdict | Should -Be 'Retire'
        $scores[-1].Verdict | Should -Be 'Keep'
    }
    It 'projects trust after retiring noisy rules' {
        # 29 alerts, 16 acted on (55.2%). Retiring "Noise" removes 12 alerts, 0 acted on: 16 / 17 = 94.1%
        $p = Get-TrustProjection -Rule $scores
        $p.CurrentTrustPct | Should -Be 55.2
        $p.AlertsRemoved | Should -Be 12
        $p.ProjectedTrustPct | Should -Be 94.1
    }
    It 'respects custom thresholds' {
        $loose = Get-AlertRuleScore -Alert $alerts -Ticket $tickets -Owner $owners -MinFires 50
        ($loose | Where-Object Rule -eq 'Noise').Verdict | Should -Be 'Tune'
    }
}

Describe 'Get-SiteCorrelation' {
    It 'collapses a burst at one site into one event' {
        $a = @(
            (New-A 'WAN' -Site 'S1' -At 0), (New-A 'Heartbeat' -Site 'S1' -At 2), (New-A 'Printer' -Site 'S1' -At 3),
            (New-A 'Disk' -Site 'S1' -At 60),
            (New-A 'WAN' -Site 'S2' -At 0)
        )
        $c = Get-SiteCorrelation -Alert $a -WindowMinutes 5
        $c.Summary.Alerts | Should -Be 5
        $c.Summary.Events | Should -Be 3
        $c.Summary.ReductionPct | Should -Be 40
        ($c.Sites | Where-Object Site -eq 'S1').LargestBurst | Should -Be 3
    }
}

Describe 'Get-ResponseMetric' {
    It 'reports median detect and resolve times' {
        $a = @((New-A 'R' -Ticket 'T1'), (New-A 'R' -Ticket 'T2'), (New-A 'R' -Ticket 'T3'), (New-A 'R'))
        $t = @{ T1 = (New-T 'T1' -OpenAt 2 -ResolveAt 30); T2 = (New-T 'T2' -OpenAt 4 -ResolveAt 60); T3 = (New-T 'T3' -OpenAt 10 -ResolveAt 90) }
        $m = Get-ResponseMetric -Alert $a -Ticket $t
        $m.Overall.Tickets | Should -Be 3
        $m.Overall.MedianMttdMin | Should -Be 4
        $m.Overall.MedianMttrMin | Should -Be 60
    }
}

Describe 'Import-AlertTrustData' {
    It 'maps custom export column names through the column map' {
        $dir = Join-Path $TestDrive 'map'; $null = New-Item -ItemType Directory $dir
        @"
"Id","AlertName","Location","Host","Priority","Opened","Closed","Incident"
"1","Disk low","Office-9","srv1","P2","2026-09-01T12:00:00Z","2026-09-01T13:00:00Z","INC1"
"@ | Set-Content (Join-Path $dir 'a.csv')
        @{ alerts = @{ AlertId = 'Id'; Rule = 'AlertName'; Site = 'Location'; Device = 'Host'; Severity = 'Priority'; RaisedUtc = 'Opened'; ClearedUtc = 'Closed'; TicketId = 'Incident' } } |
            ConvertTo-Json -Depth 3 | Set-Content (Join-Path $dir 'map.json')
        $d = Import-AlertTrustData -AlertPath (Join-Path $dir 'a.csv') -ColumnMapPath (Join-Path $dir 'map.json')
        $d.Alerts[0].Rule | Should -Be 'Disk low'
        $d.Alerts[0].Site | Should -Be 'Office-9'
        $d.Alerts[0].RaisedUtc.Kind | Should -Be 'Utc'
        $d.Alerts[0].RaisedUtc.Hour | Should -Be 12
    }
}

Describe 'Invoke-AlertTrustScorecard (end to end)' {
    It 'writes a report and CSV, and HTML-encodes rule names' {
        $dir = Join-Path $TestDrive 'e2e'; $null = New-Item -ItemType Directory $dir
        @"
"AlertId","Rule","Site","Device","Severity","RaisedUtc","ClearedUtc","TicketId"
"1","<script>alert(1)</script>","S1","D1","Sev2","2026-09-01T12:00:00Z","2026-09-01T13:00:00Z","T1"
"@ | Set-Content (Join-Path $dir 'alerts.csv')
        @"
"TicketId","OpenedUtc","ResolvedUtc","Resolution"
"T1","2026-09-01T12:05:00Z","2026-09-01T13:05:00Z","Fixed"
"@ | Set-Content (Join-Path $dir 'tickets.csv')
        $out = Join-Path $dir 'out'
        $r = Invoke-AlertTrustScorecard -AlertPath (Join-Path $dir 'alerts.csv') -TicketPath (Join-Path $dir 'tickets.csv') -OutputDirectory $out
        $r.Summary.TrustScorePct | Should -Be 100
        Join-Path $out 'rule-scores.csv' | Should -Exist
        $html = Get-Content (Join-Path $out 'report.html') -Raw
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match '&lt;script&gt;'
    }
}
