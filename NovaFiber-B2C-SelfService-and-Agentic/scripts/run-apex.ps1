# Runs an anonymous Apex file against RCPOC and prints only the useful bits:
# compile problems, exceptions and USER_DEBUG lines.
param([Parameter(Mandatory)][string]$File, [string]$Org = 'RCPOC')
$j = sf apex run -o $Org -f $File --json 2>$null | Out-String | ConvertFrom-Json
$r = if ($j.status -eq 0) { $j.result } else { $j.data }
if ($r.compileProblem) { "COMPILE (line $($r.line)): $($r.compileProblem)"; exit 1 }
if ($r.exceptionMessage) { "EXCEPTION: $($r.exceptionMessage)"; "AT: $($r.exceptionStackTrace)" }
elseif ($j.status -ne 0) { "FAILED: $($j.message)" }
($r.logs -split "`n") | Where-Object { $_ -match '\|USER_DEBUG\|' } | ForEach-Object { ($_ -split '\|DEBUG\|', 2)[1] }
exit $j.status
