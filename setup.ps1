#Requires -Version 3.0
<#
.SYNOPSIS
    100% Offline / Local OSED Environment Setup for WinDbg
.DESCRIPTION
    Zero internet/network calls required. Everything is pre-bundled in the repo:
    1. Installs dark.wew theme & creates Desktop shortcut configured with -Q -WF dark.wew.
    2. Syncs dark.wew to C:\windbg_custom.wew (for attach-process.ps1).
    3. Installs PyKD (pykd.pyd) into WinDbg's winext\ directory.
    4. Installs Corelan mona.py and windbglib.py.
    5. Installs vcredist_x86.exe and registers msdia90.dll (resolves mona symbol/PDB errors).
    6. Deploys rp++ (rp-win.exe, rp++.exe, rp.exe) to PATH and osed-scripts.
    7. Copies WinDbg PyKD scripts (find-bad-chars, find-ppr, search, mona, utils) to Python Scripts folder.
    8. Adds osed-scripts and bin to User PATH.
    9. Configures _NT_SYMBOL_PATH.
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "C:\tools"
)

$ErrorActionPreference = "Continue"

# Root of the cloned repository
$RepoRoot = $PSScriptRoot
if (-not $RepoRoot) {
    $RepoRoot = (Get-Location).Path
}

Write-Host @"
=============================================================
      OSED / EXP-301 WinDbg & Tooling Local Setup
=============================================================
[+] Using repository files from: $RepoRoot
"@ -ForegroundColor Cyan

# -------------------------------------------------------------
# 1. Base Tools & Symbols Directory
# -------------------------------------------------------------
if (-not (Test-Path $InstallDir)) {
    try {
        New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction Stop | Out-Null
        Write-Host "[+] Created directory: $InstallDir" -ForegroundColor Green
    } catch {
        $InstallDir = Join-Path $env:USERPROFILE "tools"
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        Write-Host "[*] Fell back to user directory: $InstallDir" -ForegroundColor Yellow
    }
}

$SymbolsDir = "C:\Symbols"
if (-not (Test-Path $SymbolsDir)) {
    New-Item -ItemType Directory -Path $SymbolsDir -Force -ErrorAction SilentlyContinue | Out-Null
}

# -------------------------------------------------------------
# 2. Locate WinDbg (x86 prioritized for 32-bit OSED)
# -------------------------------------------------------------
Write-Host "[+] Locating WinDbg executable..." -ForegroundColor Cyan
$WinDbgCandidates = @(
    "C:\Program Files (x86)\Windows Kits\10\Debuggers\x86\windbg.exe",
    "C:\Program Files\Windows Kits\10\Debuggers\x86\windbg.exe",
    "C:\Program Files (x86)\Windows Kits\8.1\Debuggers\x86\windbg.exe",
    "C:\Program Files (x86)\Windows Kits\8.1\Debuggers\x86\windbg.exe",
    "C:\Program Files (x86)\Windows Kits\8.0\Debuggers\x86\windbg.exe",
    "C:\Program Files (x86)\Windows Kits\8.0\Debuggers\x86\windbg.exe",
    "C:\Program Files (x86)\Debugging Tools for Windows (x86)\windbg.exe",
    "C:\Program Files\Debugging Tools for Windows (x86)\windbg.exe",
    "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\windbg.exe",
    "C:\Program Files\Windows Kits\10\Debuggers\x64\windbg.exe"
)

$WinDbgPath = $null
foreach ($path in $WinDbgCandidates) {
    if (Test-Path $path) {
        $WinDbgPath = $path
        break
    }
}

if (-not $WinDbgPath) {
    $cmd = Get-Command windbg.exe -ErrorAction SilentlyContinue
    if ($cmd) { $WinDbgPath = $cmd.Source }
}

if (-not $WinDbgPath) {
    $found = Get-ChildItem -Path "C:\Program Files*" -Filter "windbg.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $WinDbgPath = $found.FullName }
}

$WinDbgDir = if ($WinDbgPath) { Split-Path $WinDbgPath } else { "C:\Program Files (x86)\Windows Kits\10\Debuggers\x86" }
$WinExtDir = Join-Path $WinDbgDir "winext"

if ($WinDbgPath) {
    Write-Host "[+] Found WinDbg at: $WinDbgPath" -ForegroundColor Green
    if (-not (Test-Path $WinExtDir)) {
        New-Item -ItemType Directory -Path $WinExtDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
} else {
    Write-Warning "[-] WinDbg not found in standard paths. Skipping WinDbg direct file copy."
}

# -------------------------------------------------------------
# 3. Setup dark.wew WinDbg Theme & Desktop Shortcut
# -------------------------------------------------------------
$SourceTheme = Join-Path $RepoRoot "dark.wew"
$DestTheme = Join-Path $InstallDir "dark.wew"
$CustomWew = "C:\windbg_custom.wew"

if (Test-Path $SourceTheme) {
    Copy-Item -Path $SourceTheme -Destination $DestTheme -Force
    Write-Host "[+] Installed theme: $DestTheme" -ForegroundColor Green
    try {
        Copy-Item -Path $SourceTheme -Destination $CustomWew -Force -ErrorAction SilentlyContinue
        Write-Host "[+] Synced theme to: $CustomWew (for attach-process.ps1)" -ForegroundColor Green
    } catch {}
} else {
    Write-Warning "[-] dark.wew not found in repo root ($SourceTheme)"
}

$Desktop = [Environment]::GetFolderPath("Desktop")
if (-not (Test-Path $Desktop)) { $Desktop = Join-Path $env:USERPROFILE "Desktop" }

if ($WinDbgPath) {
    $ShortcutPath = Join-Path $Desktop "WinDbg (Dark Theme).lnk"
    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = $WinDbgPath
        $Shortcut.Arguments = "-Q -WF `"$DestTheme`""
        $Shortcut.WorkingDirectory = $WinDbgDir
        $Shortcut.IconLocation = "$WinDbgPath,0"
        $Shortcut.Description = "WinDbg (Dark Theme)"
        $Shortcut.Save()
        Write-Host "[+] Created Desktop Shortcut: $ShortcutPath" -ForegroundColor Green
    } catch {
        Write-Warning "[-] Failed to create shortcut: $_"
    }
}

# -------------------------------------------------------------
# 4. Deploy OSED WinDbg Plugins: PyKD, Mona, windbglib
# -------------------------------------------------------------
$PluginsSource = Join-Path $RepoRoot "windbg_plugins"
Write-Host "[+] Deploying OSED WinDbg plugins from $PluginsSource..." -ForegroundColor Cyan

if (Test-Path $PluginsSource) {
    # 1. Install pykd.pyd
    $PykdSource = Join-Path $PluginsSource "pykd.pyd"
    if (Test-Path $PykdSource) {
        Copy-Item -Path $PykdSource -Destination $WinExtDir -Force -ErrorAction SilentlyContinue
        Copy-Item -Path $PykdSource -Destination $WinDbgDir -Force -ErrorAction SilentlyContinue
        Write-Host "[+] Installed pykd.pyd into $WinExtDir" -ForegroundColor Green
    }

    # 2. Install windbglib.py and mona.py
    $MonaSource = Join-Path $PluginsSource "mona.py"
    $WindbglibSource = Join-Path $PluginsSource "windbglib.py"
    if (Test-Path $MonaSource) {
        Copy-Item -Path $MonaSource -Destination $WinDbgDir -Force -ErrorAction SilentlyContinue
        Write-Host "[+] Installed mona.py into $WinDbgDir" -ForegroundColor Green
    }
    if (Test-Path $WindbglibSource) {
        Copy-Item -Path $WindbglibSource -Destination $WinDbgDir -Force -ErrorAction SilentlyContinue
        Write-Host "[+] Installed windbglib.py into $WinDbgDir" -ForegroundColor Green
    }

    # 3. Install VC++ 2008 runtime & register msdia90.dll
    $VcRedist = Join-Path $PluginsSource "vcredist_x86.exe"
    if (Test-Path $VcRedist) {
        Write-Host "[+] Installing VC++ 2008 runtime for msdia90.dll..." -ForegroundColor Cyan
        Start-Process -FilePath $VcRedist -ArgumentList "/q" -Wait -ErrorAction SilentlyContinue
    }
    
    $DiaDllPaths = @(
        "C:\Program Files (x86)\Common Files\Microsoft Shared\VC\msdia90.dll",
        "C:\Program Files\Common Files\Microsoft Shared\VC\msdia90.dll"
    )
    foreach ($dia in $DiaDllPaths) {
        if (Test-Path $dia) {
            Write-Host "[+] Registering $dia with regsvr32..." -ForegroundColor Cyan
            Start-Process -FilePath "regsvr32.exe" -ArgumentList "/s `"$dia`"" -Wait -ErrorAction SilentlyContinue
            break
        }
    }
}

# -------------------------------------------------------------
# 5. Deploy rp++ (ROP Gadget Finder)
# -------------------------------------------------------------
$BinSource = Join-Path $RepoRoot "bin"
$DestBin = Join-Path $InstallDir "bin"
New-Item -ItemType Directory -Path $DestBin -Force | Out-Null

Write-Host "[+] Deploying rp++ ROP gadget finder..." -ForegroundColor Cyan
if (Test-Path $BinSource) {
    Copy-Item -Path "$BinSource\*" -Destination $DestBin -Force -Recurse
    Write-Host "[+] Deployed rp++ binaries to $DestBin" -ForegroundColor Green
}

# -------------------------------------------------------------
# 6. Deploy epi052/osed-scripts
# -------------------------------------------------------------
$OsedSource = Join-Path $RepoRoot "osed-scripts"
$DestOsed = Join-Path $InstallDir "osed-scripts"

Write-Host "[+] Deploying osed-scripts..." -ForegroundColor Cyan
if (Test-Path $OsedSource) {
    New-Item -ItemType Directory -Path $DestOsed -Force | Out-Null
    Copy-Item -Path "$OsedSource\*" -Destination $DestOsed -Recurse -Force
    # Copy rp++ into osed-scripts directory as well
    if (Test-Path "$DestBin\rp-win.exe") {
        Copy-Item -Path "$DestBin\rp-win.exe" -Destination "$DestOsed\rp-win.exe" -Force -ErrorAction SilentlyContinue
        Copy-Item -Path "$DestBin\rp++.exe" -Destination "$DestOsed\rp++.exe" -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[+] Deployed osed-scripts to $DestOsed" -ForegroundColor Green
}

# -------------------------------------------------------------
# 7. Setup Python Environment & WinDbg PyKD Scripts
# -------------------------------------------------------------
Write-Host "[+] Detecting Python and installing scripts..." -ForegroundColor Cyan
$PythonExe = $null
$pyCmd = Get-Command python.exe -ErrorAction SilentlyContinue
if ($pyCmd) {
    $PythonExe = $pyCmd.Source
} else {
    $pyCandidates = @(
        "C:\Python39\python.exe", "C:\Python38\python.exe", "C:\Python37\python.exe",
        "C:\Python310\python.exe", "C:\Python311\python.exe", "C:\Python27\python.exe"
    )
    foreach ($cand in $pyCandidates) {
        if (Test-Path $cand) { $PythonExe = $cand; break }
    }
}

if ($PythonExe) {
    Write-Host "[+] Found Python: $PythonExe" -ForegroundColor Green
    $PythonDir = Split-Path $PythonExe
    $PyScriptsDir = Join-Path $PythonDir "Scripts"
    if (-not (Test-Path $PyScriptsDir)) {
        New-Item -ItemType Directory -Path $PyScriptsDir -Force | Out-Null
    }

    # Copy WinDbg scripts to Python's Scripts folder so '!py <script>' works directly in WinDbg
    $PykdScripts = @("find-ppr.py", "find-bad-chars.py", "search.py", "utils.py")
    foreach ($s in $PykdScripts) {
        $src = Join-Path $DestOsed $s
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $PyScriptsDir -Force
            Write-Host "[+] Copied $s -> $PyScriptsDir" -ForegroundColor Green
        }
    }
    if (Test-Path "$PluginsSource\mona.py") { Copy-Item -Path "$PluginsSource\mona.py" -Destination $PyScriptsDir -Force }
    if (Test-Path "$PluginsSource\windbglib.py") {
        Copy-Item -Path "$PluginsSource\windbglib.py" -Destination $PyScriptsDir -Force
        $sitePackages = Join-Path $PythonDir "Lib\site-packages"
        if (Test-Path $sitePackages) { Copy-Item -Path "$PluginsSource\windbglib.py" -Destination $sitePackages -Force }
    }

    # Install Python packages locally if pip is available (optional / try-catch)
    try {
        & $PythonExe -m pip install --quiet keystone-engine capstone ropper rich numpy
        Write-Host "[+] Python packages verified/installed." -ForegroundColor Green
    } catch {
        Write-Warning "[-] Pip install skipped or failed (can be run manually if offline)."
    }
} else {
    Write-Warning "[-] Python not detected in standard paths. PyKD script linking skipped."
}

# -------------------------------------------------------------
# 8. Configure Environment Variables (PATH & Symbols)
# -------------------------------------------------------------
Write-Host "[+] Configuring Environment Variables..." -ForegroundColor Cyan

# Set _NT_SYMBOL_PATH
$SymPathVal = "srv*C:\Symbols*https://msdl.microsoft.com/download/symbols"
[Environment]::SetEnvironmentVariable("_NT_SYMBOL_PATH", $SymPathVal, "User")
$env:_NT_SYMBOL_PATH = $SymPathVal
Write-Host "[+] Set _NT_SYMBOL_PATH -> $SymPathVal" -ForegroundColor Green

# Add tools, bin, and osed-scripts to User PATH
$PathsToAdd = @($InstallDir, $DestBin, $DestOsed)
$CurrentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
$NewPathList = if ([string]::IsNullOrWhiteSpace($CurrentPath)) { @() } else { $CurrentPath -split ';' }

foreach ($p in $PathsToAdd) {
    if (Test-Path $p -and ($NewPathList -notcontains $p)) {
        $NewPathList += $p
    }
    if ($env:PATH -notlike "*$p*") {
        $env:PATH = "$env:PATH;$p"
    }
}
[Environment]::SetEnvironmentVariable("PATH", ($NewPathList -join ';'), "User")
Write-Host "[+] Added directories to PATH: $DestBin, $DestOsed" -ForegroundColor Green

# Create Desktop Shortcut to OSED Tools folder
try {
    $WshShell = New-Object -ComObject WScript.Shell
    $ToolsLnk = $WshShell.CreateShortcut((Join-Path $Desktop "OSED Tools.lnk"))
    $ToolsLnk.TargetPath = $InstallDir
    $ToolsLnk.Description = "OSED Tools & Scripts"
    $ToolsLnk.Save()
} catch {}

Write-Host @"

=============================================================
  Setup Complete! Everything Installed 100% Locally!
=============================================================
[+] WinDbg Dark Theme:
    Desktop Shortcut: 'WinDbg (Dark Theme)'
    Theme file:       $DestTheme
    attach-process:   $CustomWew

[+] WinDbg Plugins & Extensions:
    PyKD:             $WinExtDir\pykd.pyd
    windbglib:        $WinDbgDir\windbglib.py
    mona.py:          $WinDbgDir\mona.py
    Symbols:          _NT_SYMBOL_PATH -> $SymPathVal

[+] Exploit Dev Tooling:
    Directory:        $DestOsed (in PATH)
    Binaries:         $DestBin (rp++.exe, rp.exe in PATH)
    Tools:            egghunter.py, find-gadgets.py, shellcoder.py
                      attach-process.ps1

[+] Quick WinDbg Commands:
    0:000> .load pykd
    0:000> !py mona
    0:000> !py find-bad-chars -a esp+4 -b 00 0a 0d
    0:000> !py find-ppr -m libspp libsync -b 00 0a 0d
    0:000> !py search -t ascii "admin"
=============================================================
"@ -ForegroundColor Green
