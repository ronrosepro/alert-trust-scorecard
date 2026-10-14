@{
    RootModule        = 'AlertTrust.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '9d3b6f2a-4c1e-4b8a-a7d2-5e9f0c1b3a64'
    Author            = 'Ron Rose'
    Description       = 'Scores monitoring alert rules on actionability, noise, flapping, ownership, and response time. Tool-agnostic: runs on CSV exports.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        'Import-AlertTrustData',
        'Get-AlertRuleScore',
        'Get-SiteCorrelation',
        'Get-ResponseMetric',
        'Get-TrustProjection',
        'Export-AlertTrustReport',
        'Invoke-AlertTrustScorecard'
    )
}
