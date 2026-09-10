#Requires -Version 3.0
<#
.SYNOPSIS
    Complete Automated OSED Environment Setup for WinDbg
.DESCRIPTION
    Configures WinDbg and all essential tooling required for Offensive Security Exploit Developer (EXP-301 / OSED):
    1. Downloads lololosys/windbg-theme (dark.wew) and configures C:\windbg_custom.wew (with offline Base64 fallback).
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

# -------------------------------------------------------------
# 0. Global SSL/TLS & Strong Crypto Fixes
# -------------------------------------------------------------
# Force TLS 1.2 (3072) and TLS 1.3 (12288) in .NET
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 3072 -bor 12288
    # Bypass untrusted / outdated root certificate errors in lab VMs
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
} catch {}

# Enable Strong Crypto and SystemDefaultTls in registry for .NET Framework (requires Admin)
try {
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' -Name 'SystemDefaultTlsVersions' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319' -Name 'SchUseStrongCrypto' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319' -Name 'SystemDefaultTlsVersions' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
} catch {}

# Universal multi-fallback download function
function Download-RemoteFile {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$Destination
    )
    
    # 1. Try curl.exe (built into modern Windows, bypasses .NET Schannel/TLS issues)
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        try {
            & $curl.Source -k -sSL -L "$Url" -o "$Destination"
            if ((Test-Path $Destination) -and ((Get-Item $Destination).Length -gt 0)) {
                return $true
            }
        } catch {}
    }

    # 2. Try Invoke-WebRequest with TLS 1.2 and cert bypass
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 3072 -bor 12288
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        if ((Test-Path $Destination) -and ((Get-Item $Destination).Length -gt 0)) {
            return $true
        }
    } catch {}

    # 3. Try System.Net.WebClient
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0")
        $wc.DownloadFile($Url, $Destination)
        if ((Test-Path $Destination) -and ((Get-Item $Destination).Length -gt 0)) {
            return $true
        }
    } catch {}

    # 4. Try certutil.exe (built-in Windows utility)
    try {
        Start-Process -FilePath "certutil.exe" -ArgumentList "-urlcache -split -f `"$Url`" `"$Destination`"" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Start-Process -FilePath "certutil.exe" -ArgumentList "-urlcache -split -f `"$Url`" delete" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        if ((Test-Path $Destination) -and ((Get-Item $Destination).Length -gt 0)) {
            return $true
        }
    } catch {}

    return $false
}

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
# 3. Setup dark.wew WinDbg Theme (With Embedded Offline Fallback)
# -------------------------------------------------------------
$ThemeFile = Join-Path $InstallDir "dark.wew"
$CustomWew = "C:\windbg_custom.wew"
$ThemeUrl = "https://raw.githubusercontent.com/lololosys/windbg-theme/master/dark.wew"

Write-Host "[+] Setting up WinDbg dark theme (dark.wew)..." -ForegroundColor Cyan
$downloadSuccess = Download-RemoteFile -Url $ThemeUrl -Destination $ThemeFile

if (-not $downloadSuccess -or -not (Test-Path $ThemeFile)) {
    Write-Host "[*] Network download failed; extracting embedded dark.wew offline copy..." -ForegroundColor Yellow
    $darkWewBase64 = "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aABvAGwAZAAxAC4AYwAAAAIAEAAEABkZGQAAAAAABAADABAABAAAAAAAIAAgAAQAAQBwAmgCAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD///8PAAAAAAAAAAABAAAAAQAAAAEAAAD8////QwAAAOsDAABfAQAABQAAAP///w8BAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////DwAAAAAAAAAAAwAAAAAAAAABAAAAvAMAAEUAAACaBQAAsAEAAAAAAAD///8PAAAAAAAAAAAEAAAAAQAAAAEAAABoAwAAlQIAAJkGAACJAwAABQAAAAcAAAALAAAAAAAAAAUAAAABAAAAAQAAAAEBAAAHAQAAvQMAAJcCAAACAAAA////DwYAAAAAAAAABgAAAAEAAAABAAAAgQAAAFABAAAtAwAA0AIAAAEAAAAAAACAAAAAAAAAAAAHAAAAAAAAAAEAAAD8AgAARQAAAJoFAACUAAAAAAAAAP///w8AAAAAAAAAAAgAAAABAAAAAQAAAM0BAABBAAAApAMAAB0CAAADAAAAAwAAAAUAAAAAAAAACQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD///8PAAAAAAAAAAAKAAAAAAAAAAEAAAC8AwAARQAAAJoFAACwAQAAAAAAAP///w8AAAAAAAAAAAsAAAAAAAAAAQAAALwDAABFAAAAmgUAALABAAAAAAAA////DwAAAAAAAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD///8PAAAAAAAAAAANAAAAAAAAAAEAAAC8AAAAwQAAAEQDAACwAQAAAgAAAAMAAAAFAAAA7wAAAAAAAwAQAAgACQAAAPgMAAABAAEAOAAsACwAAAACAAAAAwAAAP////////////////////8AAAAA1AAAAKwFAADzAwAABgAAAAMAAwB4AG4ABwAAAAYAAABkAAAAFAAAAP///w////8PBAEAAP4CAABHAAAAmAUAAJIAAAAHAAAAAQAAAAEAAABQAAAAegAAAAwDAAAKAgAAAgAAAAEAAAAEAAAAAAAAAP///w////8P////D////w8AAAAAAAAAAAMAAwCAAHQACgAAAAUAAABkAAAAFAAAAP///w////8PBQEAAL4DAABHAAAAmAUAAK4BAAAKAAAAAQAAAAEAAABAAAAAagAAAPwCAAD6AQAABQAAAAQAAAADAAAAAAAAAP///w////8P////D////w8AAAAAAAAAABQAAADLAwAAAwADAIAAdAADAAAABAAAAGQAAAAUAAAA////D////w8FAQAAvgMAAEcAAACYBQAArgEAAAMAAAABAAAAAQAAAE4EAABcAgAAhAcAAHEDAAAFAAAABwAAAAsAAAAAAAAA////D////w////8P////DwAAAAAAAAAAAAAAAAYAAAADAAMAeABsAAsAAAAHAAAAZAAAABQAAAD///8P////DwQBAAC+AwAARwAAAJgFAACuAQAACwAAAAEAAAABAAAAYAAAAIoAAAAcAwAAGgIAAAUAAAAFAAAACgAAAAAAAAD///8P////D////w////8PAAAAACAAIAADAAMAkACGAAgAAAAIAAAAZAAAABQAAAAAAACACAAAQAcAAACEAgAAAAAAALUEAADSAQAACAAAAAEAAAABAAAAzQEAAEEAAACkAwAAHQIAAAMAAAADAAAABQAAAAAAAAAAAACAAwAAQAMAAAAIAAAAAQAAAAAAAAADAAAAAQAAABEAAABAAGUAcwBwAAAAAAADAAMAeABsAAQAAAABAAAAZAAAABQAAAAAAACAAQAAQAcAAAC1BAAAAAAAAKMGAACkAQAABAAAAAEAAAABAAAAaAMAAJUCAACZBgAAiQMAAAUAAAAHAAAACwAAAAAAAAAAAACAAgAAQAEAAAACAAAAAgAAAEAAZQADAAMAkACGAAgAAAACAAAAZAAAABQAAAAAAACAAQAAQAcAAAC1BAAApAEAAKMGAAACAwAACAAAAAEAAAABAAAAEAAAADoAAADMAgAAygEAAAMAAAAAAAAABgAAAAAAAAAAAACA////DwMAAEABAABAAQAAAAAAAAARAAAAAQAAAAEAAABAAGUAcwBwAAAAAAADAAMAgAB0AAYAAAAAAAAAZAAAABQAAAAAAACAAwAAQAYAAAAAAAAA0gEAALUEAAACAwAABgAAAAEAAAABAAAAgQAAAFABAAAtAwAA0AIAAAEAAAAAAACAAAAAAAAAAAD///8P////D////w////8PAAAAAN////8AAAAAAABmAAMAAwCAAHgABQAAAAMAAABkAAAAFAAAAAAAAIAIAABABwAAAAAAAAAAAAAAhAIAANIBAAAFAAAAAQAAAAEAAAABAQAABwEAAL0DAACXAgAAAgAAAAAAAAAGAAAAAAAAAAAAAIACAABACAAAQAAAAAACAAAAAQAAAAAAAAABAAAAAQADABAABAAJAAAAIAAgADUAAAAwASYBLgBsAG8AYQBkACAAQwA6AFwAUAByAG8AZwByAGEAbQAgAEYAaQBsAGUAcwBcAEQAZQBiAHUAZwBnAGkAbgBnACAAVABvAG8AbABzACAAZgBvAHIAIABXAGkAbgBkAG8AdwBzACAAKAB4ADgANgApAFwAdwBpAG4AZQB4AHQAXABwAHkAawBkAC4AcAB5AGQACgAuAGwAbwBhAGQAIABDADoAXABQAHIAbwBnAHIAYQBtACAARgBpAGwAZQBzAFwARABlAGIAdQBnAGcAaQBuAGcAIABUAG8AbwBsAHMAIABmAG8AcgAgAFcAaQBuAGQAbwB3AHMAIAAoAHgAOAA2ACkAXAB3AGkAbgBlAHgAdABcAHAAeQBrAGQALgBwAHkAZAAKAAAAAABEAAAAEAAEAAEAAAAAAAAAMwAAAGgAXADw////AAAAAAAAAAAAAAAAkAEAAAAAAAADAgExQwBvAG4AcwBvAGwAYQBzAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    [IO.File]::WriteAllBytes($ThemeFile, [Convert]::FromBase64String($darkWewBase64))
}

Write-Host "[+] Saved theme: $ThemeFile" -ForegroundColor Green
try {
    Copy-Item -Path $ThemeFile -Destination $CustomWew -Force -ErrorAction SilentlyContinue
    Write-Host "[+] Synced theme to: $CustomWew (for attach-process.ps1)" -ForegroundColor Green
} catch {}

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

if (Download-RemoteFile -Url $PykdZipUrl -Destination $TempPykdZip) {
    try {
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
        Write-Warning "[-] PyKD extract failed: $_"
    } finally {
        Remove-Item $TempPykdZip -Force -ErrorAction SilentlyContinue
        Remove-Item $TempPykdExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Download windbglib.py and mona.py into WinDbg directory
$MonaDest = Join-Path $WinDbgDir "mona.py"
$WindbglibDest = Join-Path $WinDbgDir "windbglib.py"

if (Download-RemoteFile -Url $WindbglibUrl -Destination $WindbglibDest) {
    Write-Host "[+] Installed windbglib.py -> $WindbglibDest" -ForegroundColor Green
}
if (Download-RemoteFile -Url $MonaUrl -Destination $MonaDest) {
    Write-Host "[+] Installed mona.py -> $MonaDest" -ForegroundColor Green
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

if (Download-RemoteFile -Url $RpUrl -Destination $TempRpZip) {
    try {
        if (Test-Path $TempRpExtract) { Remove-Item $TempRpExtract -Recurse -Force }
        Expand-Archive -Path $TempRpZip -DestinationPath $TempRpExtract -Force
        
        if (Test-Path "$TempRpExtract\rp-win.exe") {
            Copy-Item -Path "$TempRpExtract\rp-win.exe" -Destination $RpExe -Force
            Copy-Item -Path "$TempRpExtract\rp-win.exe" -Destination (Join-Path $InstallDir "rp++.exe") -Force
            Copy-Item -Path "$TempRpExtract\rp-win.exe" -Destination (Join-Path $InstallDir "rp.exe") -Force
            Write-Host "[+] Installed rp++ -> $RpExe (aliased to rp++.exe and rp.exe)" -ForegroundColor Green
        }
    } catch {}
    finally {
        Remove-Item $TempRpZip -Force -ErrorAction SilentlyContinue
        Remove-Item $TempRpExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
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

    if (Download-RemoteFile -Url $ZipUrl -Destination $ZipPath) {
        try {
            if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
            Expand-Archive -Path $ZipPath -DestinationPath $ExtractPath -Force

            if (-not (Test-Path $OsedDir)) { New-Item -ItemType Directory -Path $OsedDir -Force | Out-Null }
            Copy-Item -Path "$ExtractPath\osed-scripts-main\*" -Destination $OsedDir -Recurse -Force
            Write-Host "[+] Extracted osed-scripts to $OsedDir" -ForegroundColor Green
        } catch {
            Write-Warning "[-] Failed to extract osed-scripts: $_"
        } finally {
            Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
            Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
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
