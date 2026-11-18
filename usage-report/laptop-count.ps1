# Counts your local Claude Code (Code tab) activity since 2026-10-01. Counts only: no message text leaves this PC.
# Output: claude-usage-counts.json on your Desktop. Prints PASS/FAIL at the end.
$ErrorActionPreference = 'Stop'
$root  = Join-Path $env:USERPROFILE '.claude\projects'
$since = '2026-10-01'
$out   = Join-Path ([Environment]::GetFolderPath('Desktop')) 'claude-usage-counts.json'
if (-not (Test-Path $root)) { Write-Host "FAIL: folder not found: $root"; return }

function TsHour($t) {
  if ($t -is [datetime]) { return $t.ToUniversalTime().ToString('yyyy-MM-ddTHH') }
  return ([string]$t).Substring(0, 13)
}
function Bump($key, $field, $n) {
  if (-not $script:rows.ContainsKey($key)) { $script:rows[$key] = @{ m = 0; w = 0; i = 0; s = 0; a = 0; t = 0; q = 0 } }
  $script:rows[$key][$field] += $n
}

$rows = @{}; $sess = @(); $nFiles = 0; $nBad = 0
$files = Get-ChildItem $root -Recurse -Filter *.jsonl -File | Where-Object { $_.LastWriteTime -ge [datetime]$since }
foreach ($f in $files) {
  $nFiles++
  $rel  = $f.FullName.Substring($root.Length).TrimStart('\')
  $proj = $rel.Split('\')[0]
  $isSub = $rel.Split('\').Count -gt 2          # subagent transcripts live in subfolders
  $first = $null; $last = $null; $msgs = 0
  foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
    $m = [regex]::Match($line, '"timestamp":"(\d{4}-\d\d-\d\dT\d\d)')
    if (-not $m.Success) { continue }
    $h = $m.Groups[1].Value
    if ($h -lt $since) { continue }
    if (-not $first) { $first = $h }; $last = $h
    $key = "$proj|$h"
    if ($line.Contains('"type":"assistant"')) {
      Bump $key 'a' 1
      Bump $key 't' ([regex]::Matches($line, '"type":"tool_use"')).Count
      continue
    }
    if (-not $line.Contains('"type":"user"') -or $isSub) { continue }
    if ($line.Contains('"tool_use_id"')) {
      if ($line.Contains('Request interrupted by user')) { Bump $key 'i' 1 }
      if ($line.Contains('questions have been answered') -or $line.Contains('User has answered')) { Bump $key 'q' 1 }
      continue
    }
    try { $o = $line | ConvertFrom-Json } catch { $nBad++; continue }
    if ($o.isMeta -or $o.isSidechain) { continue }
    if ($o.origin -and $o.origin.kind -and $o.origin.kind -ne 'human') { continue }
    $c = $o.message.content
    if ($c -is [string]) { $txt = $c } else { $txt = (@($c) | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ' }
    if (-not $txt) { continue }
    $tt = $txt.TrimStart()
    if ($tt.StartsWith('[Request interrupted')) { Bump $key 'i' 1; continue }
    if ($tt.StartsWith('<command-name>') -or $tt.StartsWith('/') -or $tt.StartsWith('<bash-input>')) { Bump $key 's' 1; continue }
    if ($tt.StartsWith('<local-command') -or $tt.StartsWith('Caveat:') -or $tt.StartsWith('<task-notification>') -or $tt.StartsWith('<system-reminder>') -or $tt.StartsWith('This session is being continued')) { continue }
    Bump $key 'm' 1
    Bump $key 'w' ([regex]::Matches($txt, '\S+')).Count
    $msgs++
  }
  if ($first -and -not $isSub) { $sess += [pscustomobject]@{ p = $proj; id = $f.BaseName; first = $first; last = $last; m = $msgs } }
}

$rowList = foreach ($k in $rows.Keys) { $p, $h = $k.Split('|'); $r = $rows[$k]; [pscustomobject]@{ p = $p; h = $h; m = $r.m; w = $r.w; i = $r.i; s = $r.s; a = $r.a; t = $r.t; q = $r.q } }
$result = [pscustomobject]@{ machine = $env:COMPUTERNAME; generated = (Get-Date).ToUniversalTime().ToString('o'); files = $nFiles; badLines = $nBad; sessions = $sess; rows = @($rowList) }
$result | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $out -Encoding UTF8

$totM = ($rowList | Measure-Object m -Sum).Sum; $totW = ($rowList | Measure-Object w -Sum).Sum
Write-Host "Files scanned: $nFiles   Sessions: $($sess.Count)   Your messages: $totM   Words: $totW   Unreadable lines: $nBad"
if ((Test-Path $out) -and $nFiles -gt 0) { Write-Host "PASS: saved $out  -> attach this file in the Claude chat" } else { Write-Host "FAIL: nothing saved (no transcript files since $since?)" }
