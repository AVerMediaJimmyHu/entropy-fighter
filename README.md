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

### 3. Clean-VSCodeCache.ps1 (The IntelliSense Purger)
VS Code C/C++ Extension (`ms-vscode.cpptools`) hoards gigabytes of IPCH header caches and workspace browsing databases.

* **Logic:** Scans `%LOCALAPPDATA%\Microsoft\vscode-cpptools` for IPCH and Browse DB directories older than 30 days (configurable).
* **Safety:** Runs in **Dry Run** mode by default. Warns if VS Code processes are actively locking files.
* **Usage:**
    ```powershell
    # Preview deletion (default 30 days retention)
    .\Clean-VSCodeCache.ps1

    # Execute deletion
    .\Clean-VSCodeCache.ps1 -Force

    # Purge all caches regardless of age
    .\Clean-VSCodeCache.ps1 -DaysRetention 0 -Force
    ```

### 4. Clean-JetBrainsCache.ps1 (The Index Purger)
JetBrains IDEs (IntelliJ IDEA, CLion, PyCharm, Rider, WebStorm, etc.) and Google Android Studio accumulate massive symbol indexes, compiler caches, and log files.

* **Logic:**
  * Detects installed IDE products, automatically sorts versions into `[Active / Latest]` and `[Legacy / Orphan]`.
  * Scans cache subdirectories (`caches`, `index`, `compile-server`, `log`, etc.) older than 30 days.
  * Optionally purges entire obsolete/legacy IDE directories when `-PurgeOldVersions` is specified.
* **Safety:** Runs in **Dry Run** mode by default. Warns if active IDE processes are running. Provides interactive next steps after every scan.
* **Usage:**
    ```powershell
    # Preview deletion (default 30 days retention)
    .\Clean-JetBrainsCache.ps1

    # Execute deletion
    .\Clean-JetBrainsCache.ps1 -Force

    # Purge entire legacy IDE versions + clean active caches
    .\Clean-JetBrainsCache.ps1 -PurgeOldVersions -Force

    # Purge all caches regardless of age
    .\Clean-JetBrainsCache.ps1 -DaysRetention 0 -Force
    ```

### 5. Clean-QtCreatorCache.ps1 (The Clangd Purger)
Qt Creator and modern C++ extensions produce large Clangd AST symbol index caches and QML compilation temporary files.

* **Logic:** Scans `%LOCALAPPDATA%\clangd\index`, `%LOCALAPPDATA%\QtProject\QtCreator`, and `%APPDATA%\QtProject\qtcreator` for caches and logs older than 30 days.
* **Safety:** Runs in **Dry Run** mode by default. Warns if Qt Creator or Clangd processes are active. Preserves IDE settings.
* **Usage:**
    ```powershell
    # Preview deletion (default 30 days retention)
    .\Clean-QtCreatorCache.ps1

    # Execute deletion
    .\Clean-QtCreatorCache.ps1 -Force

    # Purge all caches regardless of age
    .\Clean-QtCreatorCache.ps1 -DaysRetention 0 -Force
    ```

### 6. Clean-NuGetCache.ps1 (The Package Reclaimer)
.NET, C#, and C++ CLI builds accumulate gigabytes of immutable package versions in the global NuGet cache.

* **Logic:** Scans `%USERPROFILE%\.nuget\packages` and `%LOCALAPPDATA%\NuGet\v3-cache` for package versions older than 30 days.
* **Safety:** Runs in **Dry Run** mode by default. Warns if active build processes are running.
* **Usage:**
    ```powershell
    # Preview deletion (default 30 days retention)
    .\Clean-NuGetCache.ps1

    # Execute deletion
    .\Clean-NuGetCache.ps1 -Force

    # Purge all package versions regardless of age
    .\Clean-NuGetCache.ps1 -DaysRetention 0 -Force
    ```

## ⚠️ Disclaimer

These scripts are provided "as is". 
* **CopyJira** does not crack encryption; it automates legitimate UI interactions to save physical effort.
* **Clean-*Cache** scripts delete files. Double-check the output before forcing deletion.

## 👤 Author

**Dolphin** (feat. Brigette Aurora)
