# Mend.io 離線掃描自動化規格與維運手冊

本手冊規範在 Windows Build Server / Agent 環境下，透過 PowerShell 搭配 NTFS Directory Junction 進行 Mend.io (原 WhiteSource) 離線掃描與自動上傳之標準作業流程。

---

## 1. 系統架構與設計核心

* **零實體磁碟 I/O**：使用 Windows 原生目錄連接點 (Directory Junction, `New-Item -ItemType Junction`) 將多個散落的相依模組虛擬掛載至 `MendRunner/Scan/SourceCode`，不複製檔案，節省大量磁碟讀寫並加速 CI 流程。
* **封閉式安全邊界 (Hermetic Boundary)**：嚴格限制僅接受**相對於設定檔的相對路徑**，禁止絕對路徑與跳出專案範圍的 Path Traversal (`..`)，保證建置環境封閉性與安全隔離。
* **目錄結構鏡像還原**：於掃描工作區完整還原專案的相對目錄樹階層（如 `services/auth-service`），使 Mend.io 控制台上的弱點檔案路徑與 Git Repo 完全 100% 一致。
* **安全釋放與零資料風險保證 (Safe Junction Unlinking)**：
  - 專屬 `Remove-StagingDirectory` 清理機制，優先透過 ReparsePoint 標籤逐一解除 Junction 連接點。
  - **僅解除虛擬連接，絕不向內遞迴刪除目標原始檔案**。
  - 透過 `try-finally` 保證每次執行後釋放暫存檔案與虛擬目錄。

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
│   │   └── SourceCode/                   # 鏡像掛載與掃描之暫存根目錄 (services/auth-service...)
│   ├── UploadFile/
│   │   ├── Upload.bat                    # 顧問提供之上傳 Script
│   │   └── update-request.txt            # 上傳中繼檔案 (自動產生與清理)
│   └── whitesource/
│       └── update-request.txt            # Unified Agent 離線掃描產物
│
├── your-project/                         # Git Clone 的應用程式專案根目錄
│   ├── configs/
│   │   └── mend-config.json              # 專案相依與產品設定檔
│   ├── services/
│   └── shared/
│
└── Invoke-MendBatchScan.ps1              # 核心自動化掃描腳本
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
| `projects[].name` | String | **是** | 專案基礎名稱（掃描時會自動後綴 `-${VersionTag}`）。 |
| `projects[].paths` | Array (String) | **是** | 該專案需納入掃描的目錄清單（相對於專案根目錄）。**必須遵守以下安全規則**。 |

---

### 階層式憑證解析優先順序 (Hierarchical Fallback)

為了同時兼顧**單一專案的自包含性 (Self-contained)** 與 **CI/CD 機密安全性**，腳本採用三層式覆蓋架構：

$$\text{1. CLI 參數傳入 (-ApiKey / -UserKey)} \;\longrightarrow\; \text{2. 環境變數 (\$env:MEND_API_KEY / \$env:MEND_USER_KEY)} \;\longrightarrow\; \text{3. mend-config.json 設定檔}$$

* **本機快速測試**：可直接將 `apiKey`（或 `userKey`）寫在 `mend-config.json` 內，執行時免傳參數。
* **CI/CD 自動化**：Jenkins 可透過 Secret Text 注入環境變數，自動覆蓋 JSON 中的設定，避免個人憑證外洩。

---

> ### ⚠️ 路徑安全限制 (Path Validation Rules)
> 1. **強制相對路徑**：基準為解析後的專案根目錄 (`ProjectRoot`)。**嚴禁使用絕對路徑**（如 `C:\repo` 或 `D:\libs`），一旦偵測到絕對路徑將立即拋出例外並中止作業。
> 2. **禁止目錄逃逸 (No Path Traversal)**：若路徑包含 `..`，解析後的真實路徑必須嚴格位於專案根目錄範疇之內。若超出專案範圍（例如 `../../OtherRepo`），將直接阻斷並拋出例外。

---

## 4. 腳本參數與 CLI 用法

### 參數清單

| 參數名稱 | 型別 | 必填 | 預設值 | 說明 |
| :--- | :--- | :---: | :--- | :--- |
| `-ConfigFile` | String | **是** | - | `mend-config.json` 的檔案路徑 (例如 `.\.jenkins\mend-config.json`)。 |
| `-VersionTag` | String | **是** | - | 建置版本標籤 (例如 `2026.08.18`, `1.0.0`, 或 Git Commit Hash)。 |
| `-ProjectRoot` | String | 否 | 自動感知 | 專案根目錄路徑。若未提供，腳本會自設定檔所在目錄或其父目錄自動解析。 |
| `-MendDir` | String | 否 | `.\Mend_Windows_scan-OfflineScan` | Mend 工具包根目錄。 |
| `-ApiKey` | String | 否 | `$env:MEND_API_KEY` | Mend 組織 API Key。 |
| `-UserKey` | String | 否 | `$env:MEND_USER_KEY` | Mend 使用者 Key。 |
| `-DryRun` | Switch | 否 | `$false` | 僅組裝 Junction 並輸出鏡像目錄檢視表，**不執行 Java 離線掃描與上傳**。 |
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

## 5. Jenkins CI/CD 整合實務

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

## 6. 維運與故障排除 (Troubleshooting)

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