<#
.SYNOPSIS
    Mend.io (WhiteSource) Offline Scan & Upload Automation Runner for Windows.
.DESCRIPTION
    1. 支援從專案目錄直接讀取 JSON 設定檔（嚴格限制相對路徑，防止目錄逃逸）。
    2. 自動在 MendRunner/Scan/SourceCode 下以鏡像相對目錄結構建立 NTFS Directory Junction，零磁碟 I/O 完成依賴組裝。
    3. 智慧多技術棧支援：自動識別 Android/Gradle 專案，動態嗅探 .gradle 快取並注入 PATH，專案結束後自動還原環境；Qt 等非 Gradle 專案零干擾。
    4. 專屬安全清理機制，優先解除 ReparsePoint (Junction) 連接點，確保絕不傷及原始程式碼檔案。
    5. 支援 -DryRun 與 -PauseBeforeScan 參數以供手動檢視目錄組裝結果。
    6. 依序執行 Mend Offline 掃描與 Upload.bat 上傳，並於 finally 區塊保證強制釋放資源與環境隔離。
.PARAMETER ConfigFile
    專案 JSON 設定檔路徑 (例如 ".\mend-config.json" 或 "D:\repo\my-app\mend-config.json")。
.PARAMETER VersionTag
    Pipeline 建置版本號 (例如 "2026.08.18" 或 "1.2.0")。
.PARAMETER MendDir
    顧問提供的 Mend 工具包目錄 (預設為腳本同層目錄下的 Mend_Windows_scan-OfflineScan)。
.PARAMETER ApiKey
    Mend 組織 API Key (未提供則自動讀取環境變數 MEND_API_KEY)。
.PARAMETER UserKey
    Mend 使用者 Key (未提供則自動讀取環境變數 MEND_USER_KEY)。
.PARAMETER DryRun
    開關：僅組裝與輸出目錄結構檢視表，不執行 Java 掃描與上傳。
.PARAMETER PauseBeforeScan
    開關：組裝完畢後暫停，供工程師以 Windows 檔案總管手動確認目錄內容。
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $true)]
    [string]$VersionTag,

    [string]$ProjectRoot,
    [string]$MendDir = (Join-Path $PSScriptRoot "Mend_Windows_scan-OfflineScan"),
    [string]$ApiKey = $env:MEND_API_KEY,
    [string]$UserKey = $env:MEND_USER_KEY,

    [switch]$DryRun,
    [switch]$PauseBeforeScan
)

$ErrorActionPreference = "Stop"

# ==========================================
# 輔助函式：安全清理 (僅卸載 Junction，絕不傷及 Target 原始碼)
# ==========================================
function Remove-StagingDirectory {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) { return }

    # 1. 遞迴尋找所有 ReparsePoint (Junction) 連接點並個別解除
    Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint
    } | ForEach-Object {
        try {
            $_.Delete()
        } catch {
            & cmd.exe /c "rmdir `"$($_.FullName)`"" 2>$null
        }
    }

    # 2. Junction 連接點全數卸載後，安全清理暫存的父層空目錄
    Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
}

# ==========================================
# 輔助函式：Gradle 專案偵測與動態 PATH 嗅探
# ==========================================
function Test-IsGradleProject {
    param (
        [string[]]$TargetPaths,
        [string]$ProjectRoot
    )

    # 1. 檢查專案根目錄
    if ((Test-Path (Join-Path $ProjectRoot "build.gradle")) -or
        (Test-Path (Join-Path $ProjectRoot "build.gradle.kts")) -or
        (Test-Path (Join-Path $ProjectRoot "gradle\wrapper\gradle-wrapper.properties"))) {
        return $true
    }

    # 2. 檢查各掛載子路徑
    foreach ($p in $TargetPaths) {
        if (-not (Test-Path $p)) { continue }
        if ((Test-Path (Join-Path $p "build.gradle")) -or
            (Test-Path (Join-Path $p "build.gradle.kts")) -or
            (Test-Path (Join-Path $p "gradle\wrapper\gradle-wrapper.properties"))) {
            return $true
        }
    }

    return $false
}

function Resolve-GradleBinPath {
    param (
        [string]$ProjectRoot,
        [string[]]$TargetPaths
    )

    # 1. 檢查目前系統 PATH 是否已有 gradle
    $existingGradle = Get-Command "gradle" -ErrorAction SilentlyContinue
    if ($existingGradle) {
        Write-Host "  [Gradle 探測] 系統 PATH 已包含 gradle: $($existingGradle.Source)" -ForegroundColor DarkGray
        return $null
    }

    Write-Host "  [Gradle 探測] 偵測到 Gradle 依賴特徵，系統 PATH 未設定 gradle，啟動自動嗅探..." -ForegroundColor Cyan

    # 2. 尋找 gradle-wrapper.properties 並解析版本
    $wrapperCandidates = @(
        (Join-Path $ProjectRoot "gradle\wrapper\gradle-wrapper.properties")
    )
    foreach ($p in $TargetPaths) {
        $wrapperCandidates += (Join-Path $p "gradle\wrapper\gradle-wrapper.properties")
        $wrapperCandidates += (Join-Path $p "wrapper\gradle-wrapper.properties")
    }

    $foundWrapperProp = $null
    foreach ($cand in $wrapperCandidates) {
        if (Test-Path $cand) {
            $foundWrapperProp = $cand
            break
        }
    }

    $targetDistName = $null
    if ($foundWrapperProp) {
        Write-Host "  [Gradle 探測] 讀取 Wrapper 設定: $foundWrapperProp" -ForegroundColor DarkGray
        $content = Get-Content -Path $foundWrapperProp -Raw -ErrorAction SilentlyContinue
        if ($content -match 'distributionUrl\s*=\s*.*?(gradle-[0-9\.]+(?:-[a-zA-Z0-9]+)?(?:-bin|-all)?\.zip)') {
            $zipName = $matches[1]
            $targetDistName = [System.IO.Path]::GetFileNameWithoutExtension($zipName)
            Write-Host "  [Gradle 探測] 目標版本名稱: $targetDistName" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  [Gradle 探測] 未在專案目錄中找到 gradle-wrapper.properties" -ForegroundColor DarkGray
    }

    # 3. 搜尋本機 Gradle 快取 (優先檢查 GRADLE_USER_HOME 環境變數，未設定則 fallback 至 UserProfile)
    $gradleDistsRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($env:GRADLE_USER_HOME) -and (Test-Path $env:GRADLE_USER_HOME)) {
        $gradleDistsRoot = Join-Path $env:GRADLE_USER_HOME "wrapper\dists"
        Write-Host "  [Gradle 探測] 依據環境變數 GRADLE_USER_HOME 搜尋快取: $gradleDistsRoot" -ForegroundColor DarkGray
    } else {
        $userProfile = [Environment]::GetFolderPath("UserProfile")
        $gradleDistsRoot = Join-Path $userProfile ".gradle\wrapper\dists"
        Write-Host "  [Gradle 探測] 搜尋本機預設快取目錄: $gradleDistsRoot" -ForegroundColor DarkGray
    }

    if (Test-Path $gradleDistsRoot) {
        # A. 優先精確匹配目標版本
        if ($targetDistName) {
            $matchedDists = Get-ChildItem -Path (Join-Path $gradleDistsRoot "$targetDistName*") -Directory -ErrorAction SilentlyContinue
            foreach ($distDir in $matchedDists) {
                $gradleExe = Get-ChildItem -Path $distDir.FullName -Filter "gradle.bat" -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($gradleExe) {
                    $binDir = Split-Path $gradleExe.FullName -Parent
                    Write-Host "  [Gradle 探測] 精確版本匹配成功: $($gradleExe.FullName)" -ForegroundColor Green
                    return $binDir
                }
            }
        }

        # B. Fallback: 尋找快取中最新版本的 gradle.bat
        $allGradleExes = Get-ChildItem -Path $gradleDistsRoot -Filter "gradle.bat" -Recurse -Depth 5 -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if ($allGradleExes -and $allGradleExes.Count -gt 0) {
            $fallbackExe = $allGradleExes[0]
            $binDir = Split-Path $fallbackExe.FullName -Parent
            Write-Host "  [Gradle 探測] 未精確比對，採用本機最新快取: $($fallbackExe.FullName)" -ForegroundColor Yellow
            return $binDir
        }
    }

    Write-Warning "  [Gradle 探測] 在 $gradleDistsRoot 找不到任何可用的 gradle.bat。若掃描失敗，請確認該專案曾以 Android Studio 或 gradlew 執行過一次建置。"
    return $null
}

# ==========================================
# 1. 環境驗證與路徑解析
# ==========================================
if (-not (Test-Path $ConfigFile)) {
    throw "設定檔不存在: $ConfigFile"
}

$ConfigFileObj = Resolve-Path $ConfigFile
$ConfigDir = Split-Path $ConfigFileObj.Path -Parent

# 讀取並解析 JSON
$config = Get-Content -Path $ConfigFileObj.Path -Raw -Encoding UTF8 | ConvertFrom-Json
$ProductName = $config.productName

if ([string]::IsNullOrWhiteSpace($ProductName)) {
    throw "設定檔內未定義 productName。"
}

# 解析專案根目錄與安全邊界 (優先順序: CLI -ProjectRoot > JSON projectRoot > 自動感知 .jenkins/.ci 目錄 > ConfigDir)
$ResolvedProjectRoot = $null
if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ResolvedProjectRoot = (Resolve-Path $ProjectRoot).Path
} elseif (-not [string]::IsNullOrWhiteSpace($config.projectRoot)) {
    $ResolvedProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $ConfigDir $config.projectRoot))
} else {
    $configDirLeaf = Split-Path $ConfigDir -Leaf
    $parentDir = Split-Path $ConfigDir -Parent
    if ($configDirLeaf -in @(".jenkins", ".ci", "configs", ".github") -and (Test-Path $parentDir)) {
        $ResolvedProjectRoot = [System.IO.Path]::GetFullPath($parentDir)
        Write-Host "[自動感知] 偵測到設定檔位於 $configDirLeaf 目錄，專案根目錄自動設定為: $ResolvedProjectRoot" -ForegroundColor DarkGray
    } else {
        $ResolvedProjectRoot = $ConfigDir
    }
}

$CanonicalProjectRoot = ([System.IO.Path]::GetFullPath($ResolvedProjectRoot)).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar

$MendDirObj = Resolve-Path $MendDir

# 階層式解析憑證 (優先順序: CLI 參數 > 環境變數 > JSON 設定檔)
if ([string]::IsNullOrWhiteSpace($ApiKey) -and -not [string]::IsNullOrWhiteSpace($config.apiKey)) {
    $ApiKey = $config.apiKey
}
if ([string]::IsNullOrWhiteSpace($UserKey) -and -not [string]::IsNullOrWhiteSpace($config.userKey)) {
    $UserKey = $config.userKey
}

# 驗證憑證 (DryRun 模式下可跳過)
if (-not $DryRun) {
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw "缺少 Mend ApiKey，請透過參數傳入、設定環境變數 MEND_API_KEY 或在設定檔中指定 apiKey。"
    }
    if ([string]::IsNullOrWhiteSpace($UserKey)) {
        throw "缺少 Mend UserKey，請透過參數傳入、設定環境變數 MEND_USER_KEY 或在設定檔中指定 userKey。"
    }
}

# 解析 Java 執行檔
$JavaExe = Join-Path $MendDirObj.Path "Scan\Config\zulu11.68.17\bin\java.exe"
if (-not (Test-Path $JavaExe)) {
    $JavaExe = Join-Path $MendDirObj.Path "Config\zulu11.68.17\bin\java.exe"
}
if (-not (Test-Path $JavaExe)) {
    $JavaExe = "java"
}

# 尋找 Unified Agent Jar
$AgentJarItem = Get-ChildItem -Path (Join-Path $MendDirObj.Path "Scan\Config\UnifiedAgent") -Filter "wss-unified-agent-*.jar" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $AgentJarItem) {
    $AgentJarItem = Get-ChildItem -Path (Join-Path $MendDirObj.Path "Config\UnifiedAgent") -Filter "wss-unified-agent-*.jar" -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $AgentJarItem -and -not $DryRun) {
    throw "在 $($MendDirObj.Path) 內找不到 wss-unified-agent-*.jar"
}

# 定義固定組裝與輸出目錄
$ScanDir = Join-Path $MendDirObj.Path "Scan"
$UploadDir = Join-Path $MendDirObj.Path "Upload"
$SourceCodeDir = Join-Path $ScanDir "SourceCode"
$ScanConfig = Join-Path $ScanDir "Config\Scan-wss-unified-agent.config"
$UploadConfig = Join-Path $UploadDir "Config\Upload-wss-unified-agent.config"
$UpdateRequestFile = Join-Path $ScanDir "whitesource\update-request.txt"

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " Mend Batch Scan Runner" -ForegroundColor Cyan
Write-Host " Config File   : $($ConfigFileObj.Path)"
Write-Host " Product Name  : $ProductName"
Write-Host " Version Tag   : $VersionTag"
Write-Host " Project Root  : $ResolvedProjectRoot"
Write-Host " Target Staging: $SourceCodeDir"
Write-Host " Scan Dir      : $ScanDir"
Write-Host " Upload Dir    : $UploadDir"
if ($DryRun) { Write-Host " Mode          : DRY-RUN (不執行掃描與上傳)" -ForegroundColor Magenta }
Write-Host "========================================================" -ForegroundColor Cyan

# ==========================================
# 2. 依序處理各子專案
# ==========================================
foreach ($proj in $config.projects) {
    $ProjectBaseName = $proj.name
    $ProjectFullName = "${ProjectBaseName}-${VersionTag}"
    $originalPathEnv = $env:PATH

    Write-Host "`n>>> [專案開始] 處理目標: $ProjectFullName" -ForegroundColor Yellow

    try {
        # A. 安全初始化並清空 SourceCode 目錄
        Remove-StagingDirectory -Path $SourceCodeDir
        $null = New-Item -ItemType Directory -Path $SourceCodeDir -Force

        # B. 建立鏡像相對目錄階層的 Junction 虛擬目錄掛載
        $resolvedFullPaths = @()
        foreach ($pathEntry in $proj.paths) {
            # 1. 嚴格檢查：禁止絕對路徑
            if ([System.IO.Path]::IsPathRooted($pathEntry)) {
                throw "[$ProjectFullName] 違反路徑安全規範：路徑 '$pathEntry' 為絕對路徑。僅允許使用相對於專案根目錄的相對路徑。"
            }

            # 2. 正規化相對路徑並相對於 ResolvedProjectRoot 計算 Canonical Full Path
            $relPath = $pathEntry.Replace('/', '\').TrimStart('\')
            $fullSourcePath = [System.IO.Path]::GetFullPath((Join-Path $ResolvedProjectRoot $relPath))

            # 3. 嚴格檢查：防禦 Path Traversal 目錄逃逸 (禁止超出 ResolvedProjectRoot 範圍)
            $isInsideRoot = $fullSourcePath.StartsWith($CanonicalProjectRoot, [System.StringComparison]::OrdinalIgnoreCase) -or ($fullSourcePath -eq ([System.IO.Path]::GetFullPath($ResolvedProjectRoot)))
            if (-not $isInsideRoot) {
                throw "[$ProjectFullName] 違反安全邊界規範：路徑 '$pathEntry' (解析為 '$fullSourcePath') 已超出專案根目錄範圍 ($ResolvedProjectRoot)。"
            }

            if (-not (Test-Path $fullSourcePath)) {
                Write-Warning "  [Link 失敗] 找不到指定目錄: $fullSourcePath"
                continue
            }

            $resolvedFullPaths += $fullSourcePath

            # 4. 建立鏡像中繼目錄結構與 Junction
            $linkTarget = Join-Path $SourceCodeDir $relPath
            $linkParent = Split-Path $linkTarget -Parent

            if (-not (Test-Path $linkParent)) {
                $null = New-Item -ItemType Directory -Path $linkParent -Force
            }

            $null = New-Item -ItemType Junction -Path $linkTarget -Target $fullSourcePath
            Write-Host "  [Link 掛載成功] $relPath -> $fullSourcePath" -ForegroundColor Green
        }

        # C. 輸出當前組裝結果清單 (包含鏡像相對路徑)
        Write-Host "`n  --- [SourceCode 鏡像組裝目錄結構] ---" -ForegroundColor DarkGray
        Get-ChildItem -Path $SourceCodeDir -Recurse | Where-Object {
            $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint
        } | Select-Object @{
            Name = "RelativeMountPath"
            Expression = { $_.FullName.Substring($SourceCodeDir.Length).TrimStart('\') }
        }, @{
            Name = "TargetRealPath"
            Expression = { $_.Target }
        } | Format-Table -AutoSize | Out-String | Write-Host -ForegroundColor DarkGray

        # D. 專案技術棧感知：僅在 Gradle 專案時動態注入 Gradle PATH
        $isGradle = Test-IsGradleProject -TargetPaths $resolvedFullPaths -ProjectRoot $ResolvedProjectRoot
        if ($isGradle) {
            $detectedGradleBin = Resolve-GradleBinPath -ProjectRoot $ResolvedProjectRoot -TargetPaths $resolvedFullPaths
            if ($detectedGradleBin) {
                $env:PATH = "$detectedGradleBin;$env:PATH"
                Write-Host "  [Gradle 注入] 已動態將 Gradle bin 加入當前專案執行環境 PATH" -ForegroundColor Green
            }
        }

        # E. 手動檢查中斷點 (PauseBeforeScan)
        if ($PauseBeforeScan) {
            Write-Host "  [暫停確認] 目錄已建立至: $SourceCodeDir" -ForegroundColor Magenta
            Write-Host "  請開啟 Windows 檔案總管進入該目錄檢查檔案內容。" -ForegroundColor Magenta
            Read-Host "  確認無誤後請按 [Enter] 鍵繼續..."
        }

        # F. DryRun 模式跳過實際掃描
        if ($DryRun) {
            Write-Host "  [DryRun] 跳過 Java 離線掃描與上傳作業。" -ForegroundColor Cyan
            continue
        }

        # G. 執行 Mend 離線掃描 (切換工作目錄至 Scan，保證產物精確落在 Scan\whitesource)
        Write-Host "  [掃描中] 啟動 Mend Unified Agent Offline Scan..." -ForegroundColor Yellow
        Push-Location $ScanDir
        try {
            $scanArgs = @(
                "-Dfile.encoding=UTF-8",
                "-jar", $AgentJarItem.FullName
            )
            if (Test-Path $ScanConfig) {
                $scanArgs += @("-c", $ScanConfig)
            }
            $scanArgs += @(
                "-apiKey", $ApiKey,
                "-userKey", $UserKey,
                "-product", $ProductName,
                "-project", $ProjectFullName,
                "-offline", "true",
                "-d", $SourceCodeDir
            )

            & $JavaExe @scanArgs
            if ($LASTEXITCODE -ne 0) {
                throw "Mend 離線掃描失敗，回傳碼 ExitCode: $LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }

        # H. 原生 Java 呼叫上傳 (切換至 Upload 目錄，免除 bat 與 pause 阻擋)
        if (Test-Path $UpdateRequestFile) {
            Write-Host "  [上傳中] 呼叫 Unified Agent 上傳 $UpdateRequestFile..." -ForegroundColor Yellow
            Push-Location $UploadDir
            try {
                $uploadArgs = @(
                    "-Dfile.encoding=UTF-8",
                    "-jar", $AgentJarItem.FullName
                )
                if (Test-Path $UploadConfig) {
                    $uploadArgs += @("-c", $UploadConfig)
                }
                $uploadArgs += @(
                    "-apiKey", $ApiKey,
                    "-userKey", $UserKey,
                    "-requestFiles", $UpdateRequestFile
                )

                & $JavaExe @uploadArgs
                if ($LASTEXITCODE -ne 0) {
                    throw "Mend 上傳作業失敗，回傳碼 ExitCode: $LASTEXITCODE"
                }
            } finally {
                Pop-Location
            }

            # 上傳完成後清除產物，避免污染下一個專案
            Remove-Item $UpdateRequestFile -Force -ErrorAction SilentlyContinue
        } else {
            throw "掃描完成但未在 $UpdateRequestFile 找到產物。"
        }

        Write-Host ">>> [專案成功] $ProjectFullName 掃描與上傳完成。" -ForegroundColor Green

    } catch {
        Write-Error ">>> [專案失敗] 處理 $ProjectFullName 發生異常: $_"
        exit 1
    } finally {
        # I. 環境還原與安全清理：保證隔離與防誤刪
        $env:PATH = $originalPathEnv
        Remove-StagingDirectory -Path $SourceCodeDir
    }
}

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host " 所有專案批次作業已全數執行完畢。" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan