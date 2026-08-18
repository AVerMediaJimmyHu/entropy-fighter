# Mend.io 離線掃描自動化規格與維運手冊

本手冊規範在 Windows Build Server / Agent 環境下，透過 PowerShell 搭配 NTFS Directory Junction 進行 Mend.io (原 WhiteSource) 離線掃描與自動上傳之標準作業流程。

---

## 1. 系統架構與設計核心

* **零實體磁碟 I/O**：使用 Windows 原生目錄連接點 (Directory Junction, `New-Item -ItemType Junction`) 與硬連結 (HardLink) 將散落的目錄、單一檔案或萬用字元匹配項目虛擬鏡像至 `Scan/SourceCode`，不複製實體內容，節省大量磁碟讀寫並加速 CI 流程。
* **封閉式安全邊界 (Hermetic Boundary)**：嚴格限制僅接受**相對於專案根目錄的相對路徑**，禁止絕對路徑與跳出專案範圍的 Path Traversal (`..`)，保證建置環境封閉性與安全隔離。
* **目錄結構鏡像還原**：於掃描工作區完整還原專案的相對目錄樹階層（如 `services/auth-service`），使 Mend.io 控制台上的弱點檔案路徑與 Git Repo 完全 100% 一致。
* **智慧多技術棧版本萃取**：支援 Android Gradle、OBS buildspec、Qt CMake、Qt qmake (`versions.pri`) 與純文字版本檔案之動態解析與多平台命名。
* **安全釋放與零資料風險保證 (Safe Unlinking)**：
  - 專屬 `Remove-StagingDirectory` 清理機制，優先透過 ReparsePoint 標籤逐一解除 Junction 連接點，並安全卸載 HardLink。
  - **僅解除虛擬連接與暫存索引，絕不向內遞迴刪除目標原始檔案**。
  - 透過 `try-finally` 保證每次執行後釋放暫存檔案與環境變數隔離。

---

## 2. 目錄拓撲結構

標準工作區目錄結構如下：

```text
BuildAgent_Workspace/
│
├── Mend_Windows_scan-OfflineScan/        # 顧問/官方提供之工具包目錄 (可透過 -MendDir 覆寫)
│   ├── Config/ (或 Scan/Config/)
│   │   ├── UnifiedAgent/
│   │   │   └── wss-unified-agent-*.jar   # Mend Unified Agent 核心 Jar
│   │   └── zulu11.68.17/                 # 隨附 JRE 環境 (內含 bin/java.exe)
│   ├── Scan/
│   │   ├── Config/
│   │   │   └── Scan-wss-unified-agent.config
│   │   ├── SourceCode/                   # 鏡像掛載與掃描之暫存根目錄 (services/auth-service...)
│   │   └── whitesource/
│   │       └── update-request.txt        # Unified Agent 離線掃描產物
│   └── Upload/
│       ├── Config/
│       │   └── Upload-wss-unified-agent.config
│       └── whitesource/                  # 上傳記錄檔目錄
│
├── your-project/                         # Git Clone 的應用程式專案根目錄
│   ├── .jenkins/ (或 configs/)
│   │   └── mend-config.json              # 專案相依與產品設定檔
│   ├── services/
│   └── shared/
│
├── Invoke-MendBatchScan.ps1              # 核心自動化掃描腳本 (v1.7.0)
└── Resolve-ProjectVersion.ps1            # 多技術棧版本萃取模組 (v1.5.0)
```

---

## 3. 設定檔規格 (`mend-config.json`)

設定檔採 JSON 格式，定義產品名稱、可選的專案根目錄與組織憑證，以及底下包含的各個子專案與其對應的相依目錄清單。

### 範例 (支援置於專案根目錄或 `.jenkins/` 子目錄)

```json
{
  "productName": "CoreBankingSystem",
  "projectRoot": "..",
  "apiKey": "46c760a2-f2aa-4004-bfa6-71534ae8228b",
  "userKey": "",
  "projects": [
    {
      "name": "AuthService",
      "paths": [
        "services/auth-service",
        "shared/common-utils",
        "shared/legacy-crypto"
      ]
    },
    {
      "name": "PaymentService",
      "paths": [
        "services/payment-service",
        "shared/common-utils",
        "libs/external-gateway"
      ]
    },
    {
      "name": "LegacyDesktopClient",
      "paths": [
        "client/desktop-app",
        "shared/legacy-framework"
      ]
    }
  ]
}
```

### 欄位說明與約束條件

| 欄位名稱 | 型別 | 必填 | 說明與約束條件 |
| :--- | :--- | :---: | :--- |
| `productName` | String | **是** | Mend.io 控制台內顯示的 Product 名稱。 |
| `projectRoot` | String | 否 | 專案根目錄相對位置（例如置於 `.jenkins/` 時填 `".."`）。若未指定，腳本會**自動感知** `.jenkins` / `.ci` / `configs` 等目錄並自動上推一層。 |
| `apiKey` | String | 否 | Mend 組織 API Key。若專案屬於特定部門 Org 可直接填入（支援階層式覆蓋）。 |
| `userKey` | String | 否 | Mend 使用者/服務帳號 Key。建議由 CI/CD 環境變數注入，亦可填在此處。 |
| `projects` | Array | **是** | 需掃描的子專案清單。 |
| `projects[].name` | String | **是** | 專案基礎名稱。 |
| `projects[].platform` | String | 否 | 目標平台過濾。可填 `"windows"`, `"win"`, `"macos"`, `"all"`（預設為 `"all"`）。若指定特定平台，產出的 Mend 標籤會自動組合為 `${name}-${platform}-${version}`；Windows 執行時會自動略過標記為非 Windows 的項目。 |
| `projects[].version` | String | 否 | 手動指定該專案固定版本（優先權最高）。若填 `"auto"` 或留空則觸發自動萃取。 |
| `projects[].versionRule` | String | 否 | 版本萃取規則（詳見第 4 節）。未指定則使用全域 `VersionTag`。 |
| `projects[].versionFile` | String | 否 | 自訂版本檔案相對路徑（用於精確覆蓋預設搜尋目錄）。 |
| `projects[].paths` | Array (String) | **是** | 該專案需納入掃描的目錄或檔案清單（相對於專案根目錄）。支援：<br>1. **子目錄**：自動建立 NTFS Junction 虛擬鏡像。<br>2. **單一檔案**：自動建立 NTFS HardLink（如 `"buildspec.json"`, `"CMakeLists.txt"`）。<br>3. **萬用字元 (`*` / `?`)**：支援模式匹配（如 `"configs/*.json"`, `"plugins/*"`）。 |

---

### 階層式憑證解析優先順序 (Hierarchical Fallback)

為了同時兼顧**單一專案的自包含性 (Self-contained)** 與 **CI/CD 機密安全性**，腳本採用三層式覆蓋架構：

$$\text{1. CLI 參數傳入 (-ApiKey / -UserKey)} \;\longrightarrow\; \text{2. 環境變數 (\$env:MEND_API_KEY / \$env:MEND_USER_KEY)} \;\longrightarrow\; \text{3. mend-config.json 設定檔}$$

* **本機快速測試**：可直接將 `apiKey`（或 `userKey`）寫在 `mend-config.json` 內，執行時免傳參數。
* **CI/CD 自動化**：Jenkins 可透過 Secret Text 注入環境變數，自動覆蓋 JSON 中的設定，避免個人憑證外洩。

---

> ### ⚠️ 路徑安全限制與虛擬掛載規範 (Path Validation Rules)
> 1. **強制相對路徑**：基準為解析後的專案根目錄 (`ProjectRoot`)。**嚴禁使用絕對路徑**（如 `C:\repo` 或 `D:\libs`），一旦偵測到絕對路徑將立即拋出例外並中止作業。
> 2. **禁止目錄逃逸 (No Path Traversal)**：若路徑包含 `..`，解析後的真實路徑必須嚴格位於專案根目錄範疇之內。若超出專案範圍（例如 `../../OtherRepo`），將直接阻斷並拋出例外。
> 3. **安全解除掛載保證**：目錄採用 Junction、檔案採用 HardLink。掃描前組裝與掃描後清理均只卸載連接點與暫存指標，**100% 保證絕不修改或刪除原始原始碼與檔案**。

---

## 4. 多技術棧版本萃取機制 (`versionRule` 與 `versionFile`)

為了支援 Monorepo / 多技術棧專案在同一次建置中動態套用各自獨立的語意化版本號（Semantic Versioning），系統採用模組化版本解析器 ([`Resolve-ProjectVersion.ps1`](file:///D:/work/Mend_Offline_UA/Resolve-ProjectVersion.ps1))。

### 階層式版本解析優先順序 (Resolution Priority)

$$\text{1. JSON projects[].version 手動指定} \;\longrightarrow\; \text{2. versionRule 依技術棧自動萃取} \;\longrightarrow\; \text{3. CLI -VersionTag 全域標籤} \;\longrightarrow\; \text{4. 當前日期 (yyyy.MM.dd) 保底}$$

---

### `versionRule` 與 `versionFile` 的協同關係

* **`versionRule`（策略名稱）**：決定使用哪種專用語法解析器（如 Android Gradle、OBS buildspec、Qt CMake、Qt qmake 或純文字檔）。
* **`versionFile`（明確路徑覆寫，可選）**：
  * **若未指定 `versionFile`**：解析器會依照該規則的慣用目錄結構（優先檢查掛載路徑 `$p`、子模組 `$p/app`、專案根目錄）進行智慧探測。
  * **若有指定 `versionFile`**：解析器直接鎖定該特定相對路徑（例如 `"versionFile": "submodules/app/build.gradle.kts"` 或 `"versionFile": "firmware/VERSION"`），跳過通用搜尋。

---

### 支援規則一覽表與解析語法

| `versionRule` | 適用技術棧 | 預設搜尋路徑 (未填 versionFile 時) | 支援的語法與變數格式 |
| :--- | :--- | :--- | :--- |
| **`android`** | Android / Gradle | 1. `$p/app/build.gradle(.kts)`<br>2. `$p/build.gradle(.kts)`<br>3. `$p/gradle.properties`<br>4. `$p/gradle/libs.versions.toml`<br>5. 根目錄對應檔案 | • `versionName = "1.0.8"` / `versionName "1.0.8"`<br>• `versionName.set("1.0.8")`<br>• `productFlavors` 區塊（自動退回 `defaultConfig`）<br>• `VERSION_NAME=1.0.8` / `[versions]` |
| **`buildspec`**<br>(或 `obs-plugin`) | OBS 插件 / buildspec | 1. `$p/buildspec.json`<br>2. 根目錄 `buildspec.json` | • JSON 頂層 `"version": "2.4.19"` 欄位 |
| **`qt-cmake`**<br>(或 `cmake`) | Qt (CMake) | 1. `$p/CMakeLists.txt`<br>2. 根目錄 `CMakeLists.txt` | • `set(APP_VERSION_MAJOR 4)` + `MINOR` + `BUILD` $\to$ `4.0.9`<br>• `set(PROJECT_VERSION_MAJOR ...)`<br>• `project(... VERSION 4.0.9)`<br>• `set(PROJECT_VERSION "4.0.9")` |
| **`qt-qmake`**<br>(或 `pri`, `qmake`) | Qt (qmake) | 1. `$p/versions.pri`<br>2. `$p/*.pri` / `$p/*.pro`<br>3. 根目錄 `versions.pri` | • `APP_VERSION_MAJOR = 1` + `MINOR` + `MAINTENANCE` + `BUILD` $\to$ `1.1.2.72`<br>• `VERSION_MAJOR = 1` ...<br>• `VERSION = 1.1.2` |
| **`file`**<br>(或 `plain-file`) | 純文字版本檔 | 1. `$p/VERSION` / `$p/version.txt`<br>2. 根目錄 `VERSION` | • 讀取該檔案第一行非空白字串（自動 `Trim()`） |

---

### 配置範例 (`mend-config.json`)

```json
{
  "productName": "StreamingSuite",
  "projectRoot": "..",
  "projects": [
    {
      "name": "StudioControl-Android",
      "versionRule": "android",
      "paths": ["app"]
    },
    {
      "name": "StreamingCenterPLUG",
      "platform": "windows",
      "versionRule": "buildspec",
      "paths": ["plugins/StreamingCenter", "obs-plugin-core/buildspec.json"]
    },
    {
      "name": "AssistCentralPro",
      "platform": "windows",
      "versionRule": "qt-cmake",
      "paths": ["CMakeLists.txt", "MainWindow.cpp"]
    },
    {
      "name": "LiveStreamer",
      "platform": "windows",
      "versionRule": "qt-qmake",
      "versionFile": "versions.pri",
      "paths": ["client/app", "versions.pri"]
    },
    {
      "name": "CoreFirmware",
      "versionRule": "file",
      "versionFile": "firmware/VERSION",
      "paths": ["firmware"]
    }
  ]
}
```

---

## 5. 腳本參數與 CLI 用法

### 參數清單

| 參數名稱 | 型別 | 必填 | 預設值 | 說明 |
| :--- | :--- | :---: | :--- | :--- |
| `-ConfigFile` | String | **是** | - | `mend-config.json` 的檔案路徑 (例如 `.\.jenkins\mend-config.json`)。 |
| `-VersionTag` | String | 否 | 當前日期/自動萃取 | 全域預設建置版本標籤 (例如 `2026.08.18` 或 Git Commit Hash)。若專案設有 `versionRule` 則由程式碼自動萃取。 |
| `-ProjectRoot` | String | 否 | 自動感知 | 專案根目錄路徑。若未提供，腳本會自設定檔所在目錄或其父目錄自動解析。 |
| `-MendDir` | String | 否 | `.\Mend_Windows_scan-OfflineScan` | Mend 工具包根目錄。 |
| `-ApiKey` | String | 否 | `$env:MEND_API_KEY` | Mend 組織 API Key。 |
| `-UserKey` | String | 否 | `$env:MEND_USER_KEY` | Mend 使用者 Key。 |
| `-DryRun` | Switch | 否 | `$false` | 僅組裝 Junction 並輸出鏡像目錄檢視表與版本萃取結果，**不執行 Java 離線掃描與上傳**。 |
| `-PauseBeforeScan` | Switch | 否 | `$false` | 組裝完成後中斷暫停，供工程師以檔案總管手動驗證目錄內容。 |

---

### CLI 執行範例

#### 1. 快速驗證 Junction 鏡像目錄結構 (Dry-Run 模式)
適合在本機調整 `mend-config.json` 路徑時使用，不需傳入 API Key：

```powershell
.\Invoke-MendBatchScan.ps1 `
    -ConfigFile ".\mend-config.json" `
    -VersionTag "local-test" `
    -DryRun
```

#### 2. 人工檢視目錄內容 (Debug 暫停模式)
組裝完後腳本會暫停並提示路徑，確認無誤後於終端機按下 `Enter` 繼續：

```powershell
.\Invoke-MendBatchScan.ps1 `
    -ConfigFile ".\mend-config.json" `
    -VersionTag "local-debug" `
    -ApiKey "YOUR_API_KEY" `
    -UserKey "YOUR_USER_KEY" `
    -PauseBeforeScan
```

#### 3. 正式全流程執行 (透過環境變數傳遞憑證)

```powershell
$env:MEND_API_KEY = "your-organization-api-key"
$env:MEND_USER_KEY = "your-user-key"

.\Invoke-MendBatchScan.ps1 `
    -ConfigFile "D:\work\your-project\configs\mend-config.json" `
    -VersionTag "2026.08.18.1"
```

---

## 6. Jenkins CI/CD 整合實務

在 CI/CD 環境中，請務必將 Mend 憑證存放在 Jenkins Credentials Store（類型：**Secret text**），避免明文暴露於 Pipeline 腳本或日誌中。

### 憑證 ID 慣用命名
* `MEND_API_KEY_SECRET` $\to$ Mend 組織 API Key
* `MEND_USER_KEY_SECRET` $\to$ Mend 使用者 Key

---

### 範例 1：Declarative Pipeline (`Jenkinsfile`)

```groovy
pipeline {
    agent {
        node {
            label 'windows-build-agent'
        }
    }

    environment {
        // 動態產生版本號：以建置編號搭配 Commit Hash
        SCAN_VERSION_TAG = "${BUILD_NUMBER}-${env.GIT_COMMIT ? env.GIT_COMMIT.take(7) : 'manual'}"
        CONFIG_PATH      = "${WORKSPACE}\\.jenkins\\mend-config.json"
        MEND_TOOL_DIR    = "C:\\Tools\\Mend_Windows_scan-OfflineScan"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Mend Offline Scan & Upload') {
            steps {
                withCredentials([
                    string(credentialsId: 'MEND_API_KEY_SECRET', variable: 'MEND_API_KEY'),
                    string(credentialsId: 'MEND_USER_KEY_SECRET', variable: 'MEND_USER_KEY')
                ]) {
                    powershell """
                        Set-StrictMode -Version Latest
                        \$ErrorActionPreference = 'Stop'

                        Write-Host "Starting Mend Batch Scan with VersionTag: ${env.SCAN_VERSION_TAG}"

                        .\\Invoke-MendBatchScan.ps1 `
                            -ConfigFile "${env.CONFIG_PATH}" `
                            -VersionTag "${env.SCAN_VERSION_TAG}" `
                            -MendDir "${env.MEND_TOOL_DIR}" `
                            -ApiKey "${env.MEND_API_KEY}" `
                            -UserKey "${env.MEND_USER_KEY}"
                    """
                }
            }
        }
    }

    post {
        always {
            cleanWs(cleanWhenAborted: false, cleanWhenFailure: false, cleanWhenNotBuilt: false, cleanWhenSuccess: false, cleanWhenUnstable: false, deleteDirs: true)
        }
    }
}
```

---

### 範例 2：Freestyle Job 配置

1. **Build Environment 設定**：
   * 勾選 **"Use secret text(s) or file(s)"**。
   * 新增兩個 **Secret text** 變數綁定：
     * Variable: `MEND_API_KEY` $\to$ Credentials: 選擇你的 Mend ApiKey
     * Variable: `MEND_USER_KEY` $\to$ Credentials: 選擇你的 Mend UserKey

2. **Build Steps 設定**：
   * 新增建置步驟：**"Execute Windows PowerShell"**。
   * 輸入指令腳本：

```powershell
$ErrorActionPreference = "Stop"

# 使用 Jenkins 內建環境變數動態決定版本標籤
$versionTag = "$($env:BUILD_NUMBER)-$($env:GIT_COMMIT.Substring(0,7))"

.\Invoke-MendBatchScan.ps1 `
    -ConfigFile "$env:WORKSPACE\your-project\configs\mend-config.json" `
    -VersionTag $versionTag
```

---

## 7. 維運與故障排除 (Troubleshooting)

### Q1: 建立 Junction 時出現權限錯誤？
* **原因**：Windows 建立 NTFS Junction 不需要系統管理員權限 (Administrator)，但目標磁區必須為 **NTFS** 格式（ReFS / FAT32 / 網路磁碟機 SMB 不支援 Junction）。
* **檢查**：確認專案原始碼與 Mend 工具包皆位於本機 NTFS 磁碟分區。

### Q2: 刪除暫存工作區時，會不會誤刪專案原始檔案？
* **保證**：腳本內建 `Remove-StagingDirectory`，利用 .NET `ReparsePoint` 辨識機制個別解除連接點，或透過 Windows `rmdir` 卸載 Junction。**這類操作僅會刪除連接標記，完全不會向目標原始目錄進行遞迴刪除**。

### Q3: 找不到 Java 執行環境？
* **機制**：腳本優先偵測 `$MendDir\Scan\Config\zulu11.68.17\bin\java.exe` 或 `$MendDir\Config\zulu11.68.17\bin\java.exe`。若不存在，自動 fallback 呼叫系統全域 `java`。
* **處理**：若工具包無內建 JRE，請確保 Build Server 已將 Java 8/11/17 加入系統 `PATH`。

### Q4: 掃描成功但 Upload.bat 失敗？
* **檢查項目**：
  1. 檢查 `$MendDir\UploadFile\Upload.bat` 是否具備對應的 Proxy 設定（若公司環境需走 Proxy 出海）。
  2. 檢查 API Key / User Key 是否具備上傳權限或是否過期。
  3. 確認 `UploadFile\update-request.txt` 是否存在且非空檔案。

### Q5: 中途被中斷 (Abort)，Junction 是否會殘留？
* 腳本主要邏輯包覆於 `try-catch-finally`，每次執行結束或拋出例外時均會強制清空 `Scan\SourceCode`。
* 即使手動強制終止進程造成殘留，下次啟動時也會在專案開始前自動清空該目錄，不造成重複掛載衝突。