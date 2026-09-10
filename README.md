# OSED Environment Setup & Tooling

Automated setup for **WinDbg Dark Theme**, **PyKD**, **Mona.py**, **windbglib**, **rp++**, and **epi052/osed-scripts** for OSED (Offensive Security Exploit Developer / EXP-301) lab and exam environments.

---

## ⚡ Quick One-Liner Execution (Minimal Typing)

Open PowerShell as **Administrator** and run:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/MalavVyas/osed_scripts/main/setup.ps1 | iex
```

Or from the Windows **Run** prompt (`Win + R`) or `cmd.exe`:

```cmd
powershell -ep bypass -c "[Net.ServicePointManager]::SecurityProtocol = 'Tls12'; irm https://raw.githubusercontent.com/MalavVyas/osed_scripts/main/setup.ps1 | iex"
```

---

## 🛠️ Included Plugins & Tools

| Component | Purpose & Integration |
| :--- | :--- |
| **WinDbg Dark Theme** | Downloads `dark.wew`, creates desktop shortcut with `-Q -WF dark.wew`, and syncs to `C:\windbg_custom.wew` for `attach-process.ps1`. |
| **PyKD** | WinDbg Python extension (`pykd.pyd`) placed in `winext\`. Required for all Python debugging scripts. |
| **Corelan Mona & windbglib** | Installs `mona.py` and `windbglib.py`. Runs `vcredist_x86.exe` and registers `msdia90.dll` via `regsvr32` to resolve symbol/PDB crashes. |
| **rp++ (ROP Finder)** | Downloads `rp++` (v2.1.5) to `C:\tools\rp++.exe` (and aliases `rp.exe`). Used by `find-gadgets.py` and manual ROP construction. |
| **epi052/osed-scripts** | Installs `find-bad-chars.py`, `find-ppr.py`, `search.py`, `egghunter.py`, `find-gadgets.py`, `shellcoder.py`, and `attach-process.ps1`. |
| **Python Integration** | Installs `keystone-engine`, `capstone`, `ropper`, `rich`, `numpy`, and `pykd`. Copies WinDbg scripts to `<PythonDir>\Scripts` so they run directly via `!py <name>`. |
| **Microsoft Symbols** | Configures `_NT_SYMBOL_PATH` to `srv*C:\Symbols*https://msdl.microsoft.com/download/symbols`. |

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
