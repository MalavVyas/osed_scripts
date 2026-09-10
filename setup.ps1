#Requires -Version 3.0
<#
.SYNOPSIS
    Complete Automated OSED Environment Setup for WinDbg
.DESCRIPTION
    Configures WinDbg and all essential tooling required for Offensive Security Exploit Developer (EXP-301 / OSED):
    1. Downloads lololosys/windbg-theme (dark.wew) and configures C:\windbg_custom.wew.
    2. Auto-locates 32-bit WinDbg (x86) and creates a configured Desktop shortcut (-Q -WF dark.wew).
    3. Installs PyKD (Python extension for WinDbg) into winext\.
    4. Installs Corelan mona.py & windbglib.py for WinDbg.
    5. Installs/registers Microsoft DIA SDK (msdia90.dll) for symbol parsing in mona.
    6. Downloads rp++ (fast ROP gadget finder) and links it for epi052's find-gadgets.py.
    7. Clones / extracts epi052/osed-scripts into C:\tools\osed-scripts.
    8. Installs Python dependencies (keystone-engine, capstone, ropper, rich, numpy, pykd).
    9. Copies PyKD WinDbg scripts (find-bad-chars, find-ppr, search, mona, utils) to Python Scripts folder.
    10. Configures _NT_SYMBOL_PATH and adds tools to User PATH.
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "C:\tools"
)

$ErrorActionPreference = "Continue"

# Enable TLS 1.2 & TLS 1.3 for secure downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

Write-Host @"
=============================================================
      OSED / EXP-301 WinDbg & Tooling Automated Setup
=============================================================
"@ -ForegroundColor Cyan

# -------------------------------------------------------------
# 1. Base Tools & Symbols Directory
# -------------------------------------------------------------
if (-not (Test-Path $InstallDir)) {
    try {
        New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction Stop | Out-Null
        Write-Host "[+] Created tools directory: $InstallDir" -ForegroundColor Green
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
    "C:\Program Files\Windows Kits\8.1\Debuggers\x86\windbg.exe",
    "C:\Program Files (x86)\Windows Kits\8.0\Debuggers\x86\windbg.exe",
    "C:\Program Files\Windows Kits\8.0\Debuggers\x86\windbg.exe",
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
    Write-Host "[+] Found WinDbg: $WinDbgPath" -ForegroundColor Green
    if (-not (Test-Path $WinExtDir)) {
        New-Item -ItemType Directory -Path $WinExtDir -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

# -------------------------------------------------------------
# 3. Download dark.wew WinDbg Theme
# -------------------------------------------------------------
$ThemeUrl = "https://raw.githubusercontent.com/lololosys/windbg-theme/master/dark.wew"
$ThemeFile = Join-Path $InstallDir "dark.wew"
$CustomWew = "C:\windbg_custom.wew"

Write-Host "[+] Downloading WinDbg dark theme (dark.wew)..." -ForegroundColor Cyan
try {
    Invoke-WebRequest -Uri $ThemeUrl -OutFile $ThemeFile -UseBasicParsing -ErrorAction Stop
    Write-Host "[+] Saved theme: $ThemeFile" -ForegroundColor Green
    try {
        Copy-Item -Path $ThemeFile -Destination $CustomWew -Force -ErrorAction SilentlyContinue
        Write-Host "[+] Synced theme to: $CustomWew (for attach-process.ps1)" -ForegroundColor Green
    } catch {}
} catch {
    Write-Warning "[-] Failed to download dark.wew: $_"
}

# -------------------------------------------------------------
# 4. Create Desktop Shortcut for WinDbg (Dark Theme)
# -------------------------------------------------------------
$Desktop = [Environment]::GetFolderPath("Desktop")
if (-not (Test-Path $Desktop)) { $Desktop = Join-Path $env:USERPROFILE "Desktop" }

if ($WinDbgPath) {
    $ShortcutPath = Join-Path $Desktop "WinDbg (Dark Theme).lnk"
    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $Shortcut.TargetPath = $WinDbgPath
        $Shortcut.Arguments = "-Q -WF `"$ThemeFile`""
        $Shortcut.WorkingDirectory = $WinDbgDir
        $Shortcut.IconLocation = "$WinDbgPath,0"
        $Shortcut.Description = "WinDbg with Dark Theme"
        $Shortcut.Save()
        Write-Host "[+] Created Desktop Shortcut: $ShortcutPath" -ForegroundColor Green
    } catch {
        Write-Warning "[-] Failed to create shortcut: $_"
    }
}

# -------------------------------------------------------------
# 5. Setup WinDbg OSED Plugins: PyKD, windbglib, and mona.py
# -------------------------------------------------------------
Write-Host "[+] Setting up OSED Plugins (PyKD, windbglib, mona.py)..." -ForegroundColor Cyan
$PykdZipUrl = "https://raw.githubusercontent.com/corelan/windbglib/master/pykd/pykd.zip"
$WindbglibUrl = "https://raw.githubusercontent.com/corelan/windbglib/master/windbglib.py"
$MonaUrl = "https://raw.githubusercontent.com/corelan/mona/master/mona.py"

$TempPykdZip = Join-Path $env:TEMP "pykd.zip"
$TempPykdExtract = Join-Path $env:TEMP "pykd-extract"

try {
    # Download Corelan PyKD package (contains pykd.pyd and vcredist_x86.exe)
    Invoke-WebRequest -Uri $PykdZipUrl -OutFile $TempPykdZip -UseBasicParsing -ErrorAction Stop
    if (Test-Path $TempPykdExtract) { Remove-Item $TempPykdExtract -Recurse -Force }
    Expand-Archive -Path $TempPykdZip -DestinationPath $TempPykdExtract -Force

    # Install pykd.pyd into winext
    if (Test-Path "$TempPykdExtract\pykd.pyd") {
        if (Test-Path (Join-Path $WinExtDir "pykd.pyd")) {
            Copy-Item -Path (Join-Path $WinExtDir "pykd.pyd") -Destination (Join-Path $WinExtDir "pykd.pyd.bak") -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -Path "$TempPykdExtract\pykd.pyd" -Destination $WinExtDir -Force -ErrorAction SilentlyContinue
        Copy-Item -Path "$TempPykdExtract\pykd.pyd" -Destination $WinDbgDir -Force -ErrorAction SilentlyContinue
        Write-Host "[+] Installed pykd.pyd into $WinExtDir" -ForegroundColor Green
    }

    # Install VC++ 2008 / msdia90.dll if present
    if (Test-Path "$TempPykdExtract\vcredist_x86.exe") {
        Write-Host "[+] Installing VC++ runtime for msdia90.dll..." -ForegroundColor Cyan
        Start-Process -FilePath "$TempPykdExtract\vcredist_x86.exe" -ArgumentList "/q" -Wait -ErrorAction SilentlyContinue
    }
} catch {
    Write-Warning "[-] PyKD zip download failed: $_"
} finally {
    Remove-Item $TempPykdZip -Force -ErrorAction SilentlyContinue
    Remove-Item $TempPykdExtract -Recurse -Force -ErrorAction SilentlyContinue
}

# Download windbglib.py and mona.py into WinDbg directory
$MonaDest = Join-Path $WinDbgDir "mona.py"
$WindbglibDest = Join-Path $WinDbgDir "windbglib.py"

try {
    Invoke-WebRequest -Uri $WindbglibUrl -OutFile $WindbglibDest -UseBasicParsing -ErrorAction Stop
    Write-Host "[+] Installed windbglib.py -> $WindbglibDest" -ForegroundColor Green
} catch {
    Write-Warning "[-] Could not download windbglib.py: $_"
}

try {
    Invoke-WebRequest -Uri $MonaUrl -OutFile $MonaDest -UseBasicParsing -ErrorAction Stop
    Write-Host "[+] Installed mona.py -> $MonaDest" -ForegroundColor Green
} catch {
    Write-Warning "[-] Could not download mona.py: $_"
}

# Register msdia90.dll (required by mona for symbol/structure parsing)
$DiaDllPaths = @(
    "C:\Program Files (x86)\Common Files\Microsoft Shared\VC\msdia90.dll",
    "C:\Program Files\Common Files\Microsoft Shared\VC\msdia90.dll"
)
foreach ($dia in $DiaDllPaths) {
    if (Test-Path $dia) {
        Write-Host "[+] Registering $dia via regsvr32..." -ForegroundColor Cyan
        Start-Process -FilePath "regsvr32.exe" -ArgumentList "/s `"$dia`"" -Wait -ErrorAction SilentlyContinue
        break
    }
}

# -------------------------------------------------------------
# 6. Download rp++ (Essential ROP Gadget Finder for OSED)
# -------------------------------------------------------------
Write-Host "[+] Setting up rp++ (ROP gadget finder)..." -ForegroundColor Cyan
$RpUrl = "https://github.com/0vercl0k/rp/releases/download/v2.1.5/rp-win.zip"
$TempRpZip = Join-Path $env:TEMP "rp-win.zip"
$TempRpExtract = Join-Path $env:TEMP "rp-extract"
$RpExe = Join-Path $InstallDir "rp-win.exe"

try {
    Invoke-WebRequest -Uri $RpUrl -OutFile $TempRpZip -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop
    if (Test-Path $TempRpExtract) { Remove-Item $TempRpExtract -Recurse -Force }
    Expand-Archive -Path $TempRpZip -DestinationPath $TempRpExtract -Force
    
    if (Test-Path "$TempRpExtract\rp-win.exe") {
        Copy-Item -Path "$TempRpExtract\rp-win.exe" -Destination $RpExe -Force
        # Also copy as rp++.exe and rp.exe for convenient command-line use
        Copy-Item -Path "$TempRpExtract\rp-win.exe" -Destination (Join-Path $InstallDir "rp++.exe") -Force
        Copy-Item -Path "$TempRpExtract\rp-win.exe" -Destination (Join-Path $InstallDir "rp.exe") -Force
        Write-Host "[+] Installed rp++ -> $RpExe (aliased to rp++.exe and rp.exe)" -ForegroundColor Green
    }
} catch {
    Write-Warning "[-] Could not download rp++: $_"
} finally {
    Remove-Item $TempRpZip -Force -ErrorAction SilentlyContinue
    Remove-Item $TempRpExtract -Recurse -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------
# 7. Clone / Download epi052/osed-scripts
# -------------------------------------------------------------
$OsedDir = Join-Path $InstallDir "osed-scripts"
Write-Host "[+] Setting up epi052/osed-scripts in $OsedDir..." -ForegroundColor Cyan

$gitInstalled = [bool](Get-Command git -ErrorAction SilentlyContinue)

if (Test-Path (Join-Path $OsedDir ".git")) {
    Write-Host "[*] osed-scripts already exists, updating via git pull..." -ForegroundColor Yellow
    Push-Location $OsedDir; try { git pull } catch {}; Pop-Location
} elseif ($gitInstalled) {
    Write-Host "[+] Cloning osed-scripts via git..." -ForegroundColor Cyan
    git clone https://github.com/epi052/osed-scripts.git $OsedDir
} else {
    Write-Host "[*] Downloading osed-scripts ZIP from GitHub..." -ForegroundColor Yellow
    $ZipUrl = "https://github.com/epi052/osed-scripts/archive/refs/heads/main.zip"
    $ZipPath = Join-Path $env:TEMP "osed-scripts.zip"
    $ExtractPath = Join-Path $env:TEMP "osed-scripts-extract"

    try {
        Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing -ErrorAction Stop
        if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
        Expand-Archive -Path $ZipPath -DestinationPath $ExtractPath -Force

        if (-not (Test-Path $OsedDir)) { New-Item -ItemType Directory -Path $OsedDir -Force | Out-Null }
        Copy-Item -Path "$ExtractPath\osed-scripts-main\*" -Destination $OsedDir -Recurse -Force
        Write-Host "[+] Extracted osed-scripts to $OsedDir" -ForegroundColor Green
    } catch {
        Write-Warning "[-] Failed to download/extract osed-scripts: $_"
    } finally {
        Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Copy rp++ into osed-scripts directory as well
if (Test-Path $RpExe) {
    Copy-Item -Path $RpExe -Destination (Join-Path $OsedDir "rp-win.exe") -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $RpExe -Destination (Join-Path $OsedDir "rp++.exe") -Force -ErrorAction SilentlyContinue
}

# -------------------------------------------------------------
# 8. Setup Python Environment & WinDbg PyKD Scripts
# -------------------------------------------------------------
Write-Host "[+] Detecting Python and installing dependencies..." -ForegroundColor Cyan
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
    Write-Host "[+] Using Python: $PythonExe" -ForegroundColor Green
    Write-Host "[+] Installing Python dependencies (keystone-engine, capstone, ropper, rich, numpy, pykd)..." -ForegroundColor Cyan
    try {
        & $PythonExe -m pip install --quiet --upgrade pip
        & $PythonExe -m pip install --quiet keystone-engine capstone ropper rich numpy pykd
        Write-Host "[+] Python dependencies installed." -ForegroundColor Green
    } catch {
        Write-Warning "[-] Pip install warning: $_"
    }

    # Copy WinDbg scripts to Python Scripts folder for direct '!py <script>' execution
    $PythonDir = Split-Path $PythonExe
    $PyScriptsDir = Join-Path $PythonDir "Scripts"
    if (-not (Test-Path $PyScriptsDir)) {
        New-Item -ItemType Directory -Path $PyScriptsDir -Force | Out-Null
    }

    $PykdScripts = @("find-ppr.py", "find-bad-chars.py", "search.py", "utils.py")
    foreach ($s in $PykdScripts) {
        $sourceScript = Join-Path $OsedDir $s
        if (Test-Path $sourceScript) {
            Copy-Item -Path $sourceScript -Destination $PyScriptsDir -Force
            Write-Host "[+] Copied $s -> $PyScriptsDir" -ForegroundColor Green
        }
    }
    # Also copy mona.py & windbglib.py into Python Scripts & Lib\site-packages
    if (Test-Path $MonaDest) { Copy-Item -Path $MonaDest -Destination $PyScriptsDir -Force }
    if (Test-Path $WindbglibDest) {
        Copy-Item -Path $WindbglibDest -Destination $PyScriptsDir -Force
        $sitePackages = Join-Path $PythonDir "Lib\site-packages"
        if (Test-Path $sitePackages) { Copy-Item -Path $WindbglibDest -Destination $sitePackages -Force }
    }
} else {
    Write-Warning "[-] Python not detected in standard paths. Pip installation skipped."
}

# -------------------------------------------------------------
# 9. Configure Environment Variables (PATH & Symbols)
# -------------------------------------------------------------
Write-Host "[+] Configuring Environment Variables..." -ForegroundColor Cyan

# Set _NT_SYMBOL_PATH for Microsoft symbols
$SymPathVal = "srv*C:\Symbols*https://msdl.microsoft.com/download/symbols"
[Environment]::SetEnvironmentVariable("_NT_SYMBOL_PATH", $SymPathVal, "User")
$env:_NT_SYMBOL_PATH = $SymPathVal
Write-Host "[+] Set _NT_SYMBOL_PATH -> $SymPathVal" -ForegroundColor Green

# Add Tools and osed-scripts to User PATH
$PathsToAdd = @($InstallDir, $OsedDir)
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
Write-Host "[+] Added $InstallDir and $OsedDir to PATH." -ForegroundColor Green

# Create Desktop Shortcut to OSED Tools directory
try {
    $WshShell = New-Object -ComObject WScript.Shell
    $ToolsLnk = $WshShell.CreateShortcut((Join-Path $Desktop "OSED Tools.lnk"))
    $ToolsLnk.TargetPath = $InstallDir
    $ToolsLnk.Description = "OSED Tools & Scripts"
    $ToolsLnk.Save()
} catch {}

Write-Host @"

=============================================================
  Setup Complete! All OSED Plugins & Tooling Installed!
=============================================================
[+] WinDbg Dark Theme:
    Desktop Shortcut: 'WinDbg (Dark Theme)'
    Theme file:       $ThemeFile
    attach-process:   $CustomWew

[+] WinDbg Plugins & Extensions:
    PyKD:             $WinExtDir\pykd.pyd
    windbglib:        $WindbglibDest
    mona.py:          $MonaDest
    Symbols:          _NT_SYMBOL_PATH -> $SymPathVal

[+] Exploit Dev Tooling:
    Directory:        $OsedDir (in PATH)
    Tools:            egghunter.py, find-gadgets.py, shellcoder.py
                      attach-process.ps1, rp++.exe, rp.exe

[+] Quick WinDbg Commands:
    0:000> .load pykd
    0:000> !py mona
    0:000> !py find-bad-chars -a esp+4 -b 00 0a 0d
    0:000> !py find-ppr -m libspp libsync -b 00 0a 0d
    0:000> !py search -t ascii "admin"
=============================================================
"@ -ForegroundColor Green
