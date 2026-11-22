#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only integrity preflight for a privately downloaded General_apps backup.
.DESCRIPTION
  Verifies the three saved SHA-256 digests, then optionally checks the PostgreSQL
  custom-format archive with pg_restore. Does NOT connect to any database,
  restore SQL, create database objects, or edit backup files.

  Run on a trusted PC with a private copy of the full Google Drive backup folder.
  Never commit the dump, ZIP, checksum files or private inventory to GitHub.

.EXAMPLE
  .\verify-contract-registry-A1E-backup.ps1 -BackupRoot "$env:USERPROFILE\Downloads\General_apps_Backup_2026-11-22"

.EXAMPLE
  .\verify-contract-registry-A1E-backup.ps1 -BackupRoot "D:\PrivateBackups\General_apps_Backup_2026-11-22" -ReadEntireDump
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BackupRoot,
  [switch]$ReadEntireDump
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
  throw "Backup directory does not exist: $BackupRoot"
}

$files = @(Get-ChildItem -LiteralPath $BackupRoot -Recurse -File)

function Find-ExactlyOne {
  param([string]$Pattern)
  $matches = @($files | Where-Object { $_.Name -like $Pattern })
  if ($matches.Count -ne 1) {
    throw "Expected exactly one '$Pattern' in the supplied backup directory; found $($matches.Count)."
  }
  return $matches[0]
}

$checks = @(
  @{ Label = 'Database dump'; Pattern = 'General_apps.dump' },
  @{ Label = 'Roles SQL'; Pattern = 'General_apps.roles-*.sql' },
  @{ Label = 'Storage ZIP'; Pattern = 'General_apps_storage_*.zip' }
)

$dbFile = $null
foreach ($check in $checks) {
  $file = Find-ExactlyOne -Pattern $check.Pattern
  if ($check.Label -eq 'Database dump') { $dbFile = $file }

  $digestPath = $file.FullName + '.sha256'
  if (-not (Test-Path -LiteralPath $digestPath -PathType Leaf)) {
    throw "Checksum file missing for '$($file.Name)'"
  }
  $expected = ((Get-Content -LiteralPath $digestPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
  if ($expected -notmatch '^[0-9a-f]{64}$') {
    throw "Unexpected checksum format for '$($file.Name)'"
  }
  $actual = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expected) {
    throw "FAIL: SHA-256 does not match for '$($file.Name)'"
  }
  Write-Host ("PASS: {0} SHA-256 matches ({1} bytes)" -f $check.Label, $file.Length)
}

# No DB connection string is accepted. This performs archive reads only.
$restoreCommand = Get-Command pg_restore -ErrorAction SilentlyContinue
if ($restoreCommand) {
  $pgRestore = $restoreCommand.Source
} else {
  $candidate = Join-Path $env:ProgramFiles 'PostgreSQL\18\bin\pg_restore.exe'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    $pgRestore = $candidate
  } else {
    Write-Warning "pg_restore unavailable. Hashes PASS, but PostgreSQL archive parsing is NOT VERIFIED on this PC."
    Write-Host 'A compatible isolated restore remains required before A1F.'
    return
  }
}

Write-Host "Using pg_restore: $pgRestore"
$tocLines = @(& $pgRestore --list $dbFile.FullName 2>&1)
if ($LASTEXITCODE -ne 0) {
  throw "FAIL: pg_restore could not list the archive (exit code $LASTEXITCODE)."
}
$tocText = $tocLines -join "`n"
foreach ($expectedObject in @('TABLE DATA public akatsuki_tasks', 'TABLE DATA auth users')) {
  if ($tocText -notmatch [regex]::Escape($expectedObject)) {
    throw "FAIL: expected archive entry not found: $expectedObject"
  }
}
Write-Host 'PASS: pg_restore listed the archive and found representative Akatsuki/auth data entries.'

if ($ReadEntireDump) {
  # Windows reserved NUL device discards output without writing SQL to disk.
  # Explicitly no -d/-C/-c flags and no connection credentials.
  & $pgRestore --file NUL $dbFile.FullName
  if ($LASTEXITCODE -ne 0) {
    throw "FAIL: pg_restore could not stream the archive (exit code $LASTEXITCODE)."
  }
  Write-Host 'PASS: Full pg_restore archive stream was readable.'
}

Write-Host 'READ-ONLY PREFLIGHT COMPLETE. No database connection or restore was performed.'
Write-Host 'A full restore to an isolated, compatible nonproduction PostgreSQL environment is still an A1E GO prerequisite.'
