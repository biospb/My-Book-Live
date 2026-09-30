# SMB throughput benchmark for the My Book Live, run from Windows.
# Uses robocopy /J (unbuffered I/O) so the Windows client cache does not skew results.
#
#   .\smb-bench.ps1 -Label "jessie-4.19-samba4.2"
#   .\smb-bench.ps1 -Label "owrt25-ksmbd" -Share \\192.168.7.4\public -SizeGB 2 -Runs 3
#
# Results are appended to smb-bench.csv next to this script.

param(
	[Parameter(Mandatory)] [string] $Label,
	[string] $Share = '\\192.168.7.4\public',
	[int] $SizeGB = 2,
	[int] $Runs = 3
)

$ErrorActionPreference = 'Stop'
$local = Join-Path $env:TEMP 'mblbench'
$src = Join-Path $local 'src'
$dst = Join-Path $local 'dst'
$remote = Join-Path $Share '_mblbench'
$file = 'test.bin'
$csv = Join-Path $PSScriptRoot 'smb-bench.csv'

New-Item -ItemType Directory -Force $src, $dst | Out-Null
New-Item -ItemType Directory -Force $remote | Out-Null

# Incompressible test file, reused between runs and labels
$srcFile = Join-Path $src $file
$size = [int64]$SizeGB * 1GB
if (-not (Test-Path $srcFile) -or (Get-Item $srcFile).Length -ne $size) {
	Write-Host "Creating $SizeGB GiB test file..."
	$buf = New-Object byte[] (64MB)
	[System.Security.Cryptography.RandomNumberGenerator]::Fill($buf)
	$fs = [System.IO.File]::Create($srcFile)
	try { for ($i = 0; $i -lt $size / $buf.Length; $i++) { $buf[0] = [byte]$i; $fs.Write($buf, 0, $buf.Length) } }
	finally { $fs.Close() }
}

function Copy-Timed([string] $from, [string] $to) {
	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	robocopy $from $to $file /J /NP /NJH /NJS /NFL /NDL /R:0 /W:0 | Out-Null
	$sw.Stop()
	if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $from -> $to" }
	return [math]::Round($size / 1MB / $sw.Elapsed.TotalSeconds, 1)
}

$results = @()
for ($run = 1; $run -le $Runs; $run++) {
	Remove-Item (Join-Path $remote $file) -ErrorAction SilentlyContinue
	$write = Copy-Timed $src $remote

	# The file (2 GiB) is larger than the MBL RAM (256 MiB), so the read mostly comes from disk
	Remove-Item (Join-Path $dst $file) -ErrorAction SilentlyContinue
	$read = Copy-Timed $remote $dst

	Write-Host ("run {0}: write {1} MB/s, read {2} MB/s" -f $run, $write, $read)
	$results += [pscustomobject]@{
		Date = (Get-Date -Format 's'); Label = $Label; Share = $Share; SizeGB = $SizeGB
		Run = $run; WriteMBs = $write; ReadMBs = $read
	}
}

$results | Export-Csv $csv -Append -NoTypeInformation -Encoding UTF8
Remove-Item $remote -Recurse -Force
Remove-Item (Join-Path $dst $file) -ErrorAction SilentlyContinue

$w = ($results.WriteMBs | Measure-Object -Average -Maximum)
$r = ($results.ReadMBs | Measure-Object -Average -Maximum)
Write-Host ("{0}: write avg {1:N1} / max {2:N1} MB/s, read avg {3:N1} / max {4:N1} MB/s" -f $Label, $w.Average, $w.Maximum, $r.Average, $r.Maximum)
exit 0  # robocopy leaves $LASTEXITCODE = 1 ("files copied") behind
