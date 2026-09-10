# OSED Environment Setup & Tooling

Complete offline-ready setup for **WinDbg Dark Theme**, **PyKD**, **Mona.py**, **windbglib**, **rp++**, and **epi052/osed-scripts** for OSED (Offensive Security Exploit Developer / EXP-301) lab and exam environments.

All binaries, plugins, and tools are pre-packaged directly in this repository. **Zero internet downloads or SSL/TLS calls are made during execution.**

---

## ⚡ Quick Execution (Clone & Run Directly)

### Step 1: Clone the repository

```cmd
git clone https://github.com/MalavVyas/osed_scripts.git C:\tools\osed_scripts
```

### Step 2: Run setup.ps1 in Administrator PowerShell

```powershell
powershell -ep bypass -f C:\tools\osed_scripts\setup.ps1
```

Or from inside the directory:
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\setup.ps1
```

---

## 📂 Pre-Bundled Repository Structure

```text
osed_scripts/
├── dark.wew                # WinDbg Dark Theme workspace file
├── setup.ps1               # 100% offline local installer
├── bin/
│   ├── rp++.exe            # rp++ ROP gadget finder (v2.1.5)
│   ├── rp.exe
│   └── rp-win.exe
├── windbg_plugins/
│   ├── pykd.pyd            # PyKD extension for WinDbg
│   ├── windbglib.py        # Corelan WinDbg library
│   ├── mona.py             # Corelan Mona exploit development toolkit
│   └── vcredist_x86.exe    # VC++ 2008 runtime & msdia90.dll
└── osed-scripts/           # epi052 exploit scripts
    ├── attach-process.ps1  # Auto-attacher configured for dark.wew
    ├── egghunter.py
    ├── find-bad-chars.py
    ├── find-gadgets.py
    ├── find-ppr.py
    ├── search.py
    ├── shellcoder.py
    └── utils.py
```

---

## 🛠️ What `setup.ps1` Configures Locally

1. **WinDbg Dark Theme**:
   - Copies `dark.wew` to `C:\tools\dark.wew` and `C:\windbg_custom.wew` (so `attach-process.ps1` uses it automatically).
   - Creates a **Desktop shortcut** configured with `-Q -WF "C:\tools\dark.wew"`.
2. **WinDbg Extensions & Plugins**:
   - Copies `pykd.pyd` into WinDbg's `winext\` directory.
   - Copies `mona.py` and `windbglib.py` into WinDbg root.
   - Installs `vcredist_x86.exe` and registers `msdia90.dll` via `regsvr32` to ensure `mona` symbol parsing works.
3. **Exploit Dev Binaries & Tooling**:
   - Deploys `rp++` (`rp++.exe` / `rp.exe`) and `osed-scripts` to `C:\tools`.
   - Adds `C:\tools\bin` and `C:\tools\osed-scripts` to User `PATH`.
   - Copies `find-bad-chars.py`, `find-ppr.py`, `search.py`, `mona.py`, and `utils.py` to Python's `Scripts\` folder so they can be run directly inside WinDbg as `!py <name>`.
4. **Symbols**:
   - Sets `_NT_SYMBOL_PATH` to `srv*C:\Symbols*https://msdl.microsoft.com/download/symbols`.

---

## 🔍 WinDbg Cheatsheet

Once WinDbg is launched:

```text
0:000> .load pykd

# Corelan Mona
0:000> !py mona config -set workingfolder c:\mona\%p
0:000> !py mona modules
0:000> !py mona rop -m libspp.dll -cpb "\x00\x0a\x0d"

# epi052 bad chars & gadget helpers
0:000> !py find-bad-chars -a esp+4 -b 00 0a 0d
0:000> !py find-bad-chars --generate -b 00 0a 0d
0:000> !py find-ppr -m libspp libsync -b 00 0a 0d
0:000> !py search -t ascii "admin"
```
