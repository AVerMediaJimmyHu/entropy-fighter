# Entropy Fighter ⚔️

> **"Fighting the chaos of corporate IT, one script at a time."**

This repository contains a collection of "necessary evils"—PowerShell scripts designed to bypass restrictive DLP (Data Loss Prevention) software, reclaim disk space from greedy build tools, and preserve the sanity of software engineers working in high-security enterprise environments.

**Form follows frustration.**

## 📂 The Arsenal

### 1. CopyJira.ps1 (The Clipboard Liberator)
Designed to combat DLP agents that hijack the clipboard, impose arbitrary character limits, and steal window focus. It automates the "Copy + Unlock" sequence.

* **Mode:** **FPS Mode** (Left Hand `F2`, Right Hand Mouse).
* **Configuration:** * Open the script and look for the `$UnlockSequence` variable.
    * Change it to match your DLP software's specific unlock hotkey (e.g., `^%c` for Ctrl+Alt+C).
* **Usage:**
    1. Run script in PowerShell.
    2. Select text in browser.
    3. Press `F2`.
    4. Text is logged to `CopiedJira.txt` (clean & formatted).

### 2. Clean-GradleCache.ps1 (The Disk Reclaimer)
Android Studio and Gradle love to hoard old wrapper distributions.

* **Logic:** Scans `~/.gradle/wrapper/dists` for versions older than 30 days.
* **Safety:** Runs in **Dry Run** mode by default.
* **Usage:**
    ```powershell
    # Preview deletion
    .\Clean-GradleCache.ps1

    # Execute deletion
    .\Clean-GradleCache.ps1 -Force
    ```

## ⚠️ Disclaimer

These scripts are provided "as is". 
* **CopyJira** does not crack encryption; it automates legitimate UI interactions to save physical effort.
* **Clean-GradleCache** deletes files. Double-check the output before forcing deletion.

## 👤 Author

**Dolphin** (feat. Brigette Aurora)
