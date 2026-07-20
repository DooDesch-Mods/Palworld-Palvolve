# Palvolve Save Cleaner - Windows runner.
# Fetches a private Python runtime via uv (official binary from astral.sh),
# checks for PalworldSaveTools, lets you pick a world, runs a dry run first
# and asks before writing anything. Run with the game closed.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

Write-Host ""
Write-Host "Palvolve Save Cleaner" -ForegroundColor Cyan
Write-Host "Removes every Palvolve trace from a world save so it loads without the mod."
Write-Host ""

# --- PalworldSaveTools (provides the save codec) ---------------------------
$pst = Join-Path $here 'PalworldSaveTools'
if (-not (Test-Path (Join-Path $pst 'lib\palsav'))) {
    Write-Host "PalworldSaveTools is missing." -ForegroundColor Yellow
    Write-Host "1. Download PST_standalone_*.7z from:"
    Write-Host "   https://github.com/deafdudecomputers/PalworldSaveTools/releases/latest"
    Write-Host "2. Extract it (7-Zip) into this folder as 'PalworldSaveTools'"
    Write-Host "   so that PalworldSaveTools\lib\palsav exists."
    Write-Host "3. Run this script again."
    exit 1
}
$env:PST_LIB = Join-Path $pst 'lib'

# --- uv (fetches and runs Python 3.12 without installing anything) ---------
$uv = Join-Path $here 'uv.exe'
if (-not (Test-Path $uv)) {
    $sys = Get-Command uv -ErrorAction SilentlyContinue
    if ($sys) { $uv = $sys.Source }
}
if (-not (Test-Path $uv)) {
    Write-Host "Fetching uv (Python runner) from the official release..."
    $zip = Join-Path $env:TEMP 'uv-win.zip'
    Invoke-WebRequest 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip' -OutFile $zip
    Expand-Archive $zip -DestinationPath $here -Force
    Remove-Item $zip
}
if (-not (Test-Path $uv)) { Write-Host "Could not obtain uv." -ForegroundColor Red; exit 1 }

# --- world selection -------------------------------------------------------
$p = Get-Process -Name 'Palworld-Win64-Shipping' -ErrorAction SilentlyContinue
if ($p) { Write-Host "Close Palworld first, then run this again." -ForegroundColor Red; exit 1 }

$saveRoot = Join-Path $env:LOCALAPPDATA 'Pal\Saved\SaveGames'
$worlds = @(Get-ChildItem $saveRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem $_.FullName -Directory } |
    Where-Object { Test-Path (Join-Path $_.FullName 'Level.sav') } |
    Sort-Object LastWriteTime -Descending)
if ($worlds.Count -eq 0) { Write-Host "No worlds found under $saveRoot" -ForegroundColor Red; exit 1 }

Write-Host "Your worlds (newest first):"
for ($i = 0; $i -lt $worlds.Count; $i++) {
    $w = $worlds[$i]
    Write-Host ("  [{0}] {1}  (last played {2:yyyy-MM-dd HH:mm})" -f ($i + 1), $w.Name, $w.LastWriteTime)
}
$pick = Read-Host "Number of the world to clean"
$idx = [int]$pick - 1
if ($idx -lt 0 -or $idx -ge $worlds.Count) { Write-Host "Invalid choice." -ForegroundColor Red; exit 1 }
$world = $worlds[$idx].FullName

# --- dry run, then confirm -------------------------------------------------
Write-Host ""
& $uv run --python 3.12 --no-project python (Join-Path $here 'palvolve_save_cleaner.py') $world
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
$go = Read-Host "Apply these changes? A full backup of the world is made first. (y/N)"
if ($go -ne 'y' -and $go -ne 'Y') { Write-Host "Nothing written."; exit 0 }
& $uv run --python 3.12 --no-project python (Join-Path $here 'palvolve_save_cleaner.py') $world --apply
