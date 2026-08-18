<#
.SYNOPSIS
    Mend.io Automation - Project Version Resolver Module
.DESCRIPTION
    Version: 1.5.0
    Last Updated: 2026-08-18
    職責：依據專案技術棧與規則 (versionRule) 動態萃取子專案版本號，供 Mend Batch Scan 使用。
#>

function Resolve-ProjectVersion {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,

        [Parameter(Mandatory = $true)]
        $ProjectConfig,

        [string]$DefaultVersionTag = ""
    )

    $projName = $ProjectConfig.name
    $explicitVersion = $ProjectConfig.version
    $rule = $ProjectConfig.versionRule
    $flavor = $ProjectConfig.flavor
    $versionFile = $ProjectConfig.versionFile

    # 1. 優先使用手動指定的固定版本 (非 "auto" 且非空)
    if (-not [string]::IsNullOrWhiteSpace($explicitVersion) -and $explicitVersion -ne "auto") {
        Write-Host "  [版本萃取] 專案 [$projName] 採用 JSON 手動指定版本: $explicitVersion" -ForegroundColor DarkGray
        return $explicitVersion
    }

    # 2. 若未設定 versionRule，直接使用全域傳入的 DefaultVersionTag
    if ([string]::IsNullOrWhiteSpace($rule)) {
        if (-not [string]::IsNullOrWhiteSpace($DefaultVersionTag)) {
            Write-Host "  [版本萃取] 專案 [$projName] 未設定規則，採用全域 VersionTag: $DefaultVersionTag" -ForegroundColor DarkGray
            return $DefaultVersionTag
        }
        $fallbackDate = (Get-Date -Format "yyyy.MM.dd")
        Write-Host "  [版本萃取] 專案 [$projName] 未設定規則且無全域標籤，保底採用當前日期: $fallbackDate" -ForegroundColor DarkGray
        return $fallbackDate
    }

    $extractedVersion = $null

    # 3. 依據 versionRule 執行技術棧特定解析
    switch ($rule.ToLower()) {
        "android" {
            Write-Host "  [版本探測] 專案 [$projName] 開始搜尋 Android 版本定義..." -ForegroundColor Cyan

            # 搜尋目標檔案清單 (自動去重)
            $rawCandidates = @()
            $rawPropCandidates = @()

            if (-not [string]::IsNullOrWhiteSpace($versionFile)) {
                $rawCandidates += (Join-Path $ProjectRoot $versionFile)
            } else {
                # A. 優先檢查專案掛載路徑（包含其底下的 app / application 子模組）
                if ($ProjectConfig.paths) {
                    foreach ($p in $ProjectConfig.paths) {
                        $cleanP = $p.Replace('/', '\').TrimStart('\')
                        if ($cleanP -like "*build.gradle.kts" -or $cleanP -like "*build.gradle") {
                            $rawCandidates += (Join-Path $ProjectRoot $cleanP)
                        } else {
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\app\build.gradle.kts")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\app\build.gradle")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\application\build.gradle.kts")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\application\build.gradle")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\build.gradle.kts")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\build.gradle")

                            $rawPropCandidates += (Join-Path $ProjectRoot "$cleanP\gradle.properties")
                            $rawPropCandidates += (Join-Path $ProjectRoot "$cleanP\version.properties")
                            $rawPropCandidates += (Join-Path $ProjectRoot "$cleanP\gradle\libs.versions.toml")
                        }
                    }
                }
                # B. 檢查全域/頂層常見目錄
                $rawCandidates += @(
                    (Join-Path $ProjectRoot "app\build.gradle.kts"),
                    (Join-Path $ProjectRoot "app\build.gradle"),
                    (Join-Path $ProjectRoot "build.gradle.kts"),
                    (Join-Path $ProjectRoot "build.gradle")
                )
                $rawPropCandidates += @(
                    (Join-Path $ProjectRoot "gradle.properties"),
                    (Join-Path $ProjectRoot "version.properties"),
                    (Join-Path $ProjectRoot "gradle\libs.versions.toml")
                )
            }

            # 去重並保留順序
            $targetFiles = @($rawCandidates | Select-Object -Unique)
            $propFiles = @($rawPropCandidates | Select-Object -Unique)

            foreach ($file in $targetFiles) {
                $fileExists = Test-Path $file
                if ($fileExists) {
                    Write-Host "  [版本探測] 找到檔案: $file" -ForegroundColor DarkGray
                    $content = Get-Content -Path $file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if (-not [string]::IsNullOrWhiteSpace($content)) {
                        # 1. 若有指定 Flavor，先在 Flavor 區塊內尋找專屬 versionName
                        if (-not [string]::IsNullOrWhiteSpace($flavor)) {
                            $flavorRegexPattern = "(?s)(?:create\s*\(\s*[""']$flavor[""']\s*\)|$flavor\s*\{)(.*?)\}"
                            if ($content -match $flavorRegexPattern) {
                                $flavorBlock = $matches[1]
                                if ($flavorBlock -match 'versionName\s*(?:=|\.set\s*\(|\s)\s*["'']([^"'']+)["'']') {
                                    $extractedVersion = $matches[1].Trim()
                                    Write-Host "  [版本萃取] 專案 [$projName] 依據 [android(flavor=$flavor)] 專屬設定從 [$(Split-Path $file -Leaf)] 成功解析: $extractedVersion" -ForegroundColor Green
                                    break
                                }
                            }
                        }

                        # 2. 若未指定 Flavor 或該 Flavor 無專屬版本，退回提取 defaultConfig 的 versionName
                        if (-not $extractedVersion) {
                            if ($content -match '(?s)defaultConfig\s*\{(.*?)\}') {
                                $defaultConfigBlock = $matches[1]
                                if ($defaultConfigBlock -match 'versionName\s*(?:=|\.set\s*\(|\s)\s*["'']([^"'']+)["'']') {
                                    $extractedVersion = $matches[1].Trim()
                                    $flavorNotice = if (-not [string]::IsNullOrWhiteSpace($flavor)) { " (Flavor '$flavor' 無專屬版本，自動退回 defaultConfig)" } else { "" }
                                    Write-Host "  [版本萃取] 專案 [$projName] 依據 [android] defaultConfig 從 [$(Split-Path $file -Leaf)] 成功解析: $extractedVersion$flavorNotice" -ForegroundColor Green
                                    break
                                }
                            }

                            # 3. 通用全域 versionName 匹配
                            if ($content -match 'versionName\s*(?:=|\.set\s*\(|\s)\s*["'']([^"'']+)["'']') {
                                $extractedVersion = $matches[1].Trim()
                                Write-Host "  [版本萃取] 專案 [$projName] 依據 [android] 全域 versionName 從 [$(Split-Path $file -Leaf)] 成功解析: $extractedVersion" -ForegroundColor Green
                                break
                            }
                        }
                    }
                } else {
                    Write-Host "  [版本探測] (略過) 檔案不存在: $file" -ForegroundColor DarkGray
                }
            }

            # 4. 若 build.gradle 內未直接宣告，嘗試搜尋屬性檔
            if (-not $extractedVersion) {
                foreach ($propFile in $propFiles) {
                    if (Test-Path $propFile) {
                        Write-Host "  [版本探測] 檢查屬性檔: $propFile" -ForegroundColor DarkGray
                        $pContent = Get-Content -Path $propFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                        # 支援 properties 與 TOML 的版本鍵值
                        if ($pContent -match '(?m)^\s*(?:VERSION_NAME|versionName|VERSION|version|appVersion|app-version)\s*(?:=|\:)\s*["'']?([0-9A-Za-z\.\-]+)["'']?') {
                            $extractedVersion = $matches[1].Trim()
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [android] 規則從 [$(Split-Path $propFile -Leaf)] 成功解析: $extractedVersion" -ForegroundColor Green
                            break
                        }
                    } else {
                        Write-Host "  [版本探測] (略過) 屬性檔不存在: $propFile" -ForegroundColor DarkGray
                    }
                }
            }
        }

        { $_ -in @("buildspec", "buildspec.json", "obs-plugin") } {
            Write-Host "  [版本探測] 專案 [$projName] 開始搜尋 buildspec.json 版本定義..." -ForegroundColor Cyan

            $rawCandidates = @()
            if (-not [string]::IsNullOrWhiteSpace($versionFile)) {
                $rawCandidates += (Join-Path $ProjectRoot $versionFile)
            } else {
                # A. 優先檢查專案掛載路徑 (支援直接指定檔案或目錄)
                if ($ProjectConfig.paths) {
                    foreach ($p in $ProjectConfig.paths) {
                        $cleanP = $p.Replace('/', '\').TrimStart('\')
                        if ($cleanP -like "*buildspec.json" -or $cleanP -like "*.json") {
                            $rawCandidates += (Join-Path $ProjectRoot $cleanP)
                        } else {
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\buildspec.json")
                        }
                    }
                }
                # B. 檢查專案根目錄
                $rawCandidates += (Join-Path $ProjectRoot "buildspec.json")
            }

            $targetFiles = @($rawCandidates | Select-Object -Unique)

            foreach ($file in $targetFiles) {
                if (Test-Path $file) {
                    Write-Host "  [版本探測] 找到檔案: $file" -ForegroundColor DarkGray
                    try {
                        $jsonRaw = Get-Content -Path $file -Raw -Encoding UTF8 -ErrorAction Stop
                        $specObj = $jsonRaw | ConvertFrom-Json
                        if ($specObj.version) {
                            $extractedVersion = $specObj.version.ToString().Trim()
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [buildspec] 從 [$(Split-Path $file -Leaf)] 成功解析: $extractedVersion" -ForegroundColor Green
                            break
                        }
                    } catch {
                        Write-Warning "  [版本探測] 解析 JSON 檔案失敗: $file - $($_.Exception.Message)"
                    }
                } else {
                    Write-Host "  [版本探測] (略過) 檔案不存在: $file" -ForegroundColor DarkGray
                }
            }
        }

        { $_ -in @("qt-qmake", "qmake", "pri") } {
            Write-Host "  [版本探測] 專案 [$projName] 開始搜尋 qmake / pri 版本定義..." -ForegroundColor Cyan

            $rawCandidates = @()
            if (-not [string]::IsNullOrWhiteSpace($versionFile)) {
                $rawCandidates += (Join-Path $ProjectRoot $versionFile)
            } else {
                # A. 優先檢查專案掛載路徑
                if ($ProjectConfig.paths) {
                    foreach ($p in $ProjectConfig.paths) {
                        $cleanP = $p.Replace('/', '\').TrimStart('\')
                        if ($cleanP -like "*.pri" -or $cleanP -like "*.pro") {
                            $rawCandidates += (Join-Path $ProjectRoot $cleanP)
                        } else {
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\versions.pri")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\version.pri")
                        }
                    }
                }
                # B. 檢查專案根目錄
                $rawCandidates += @(
                    (Join-Path $ProjectRoot "versions.pri"),
                    (Join-Path $ProjectRoot "version.pri")
                )
            }

            $targetFiles = @($rawCandidates | Select-Object -Unique)

            foreach ($file in $targetFiles) {
                if (Test-Path $file) {
                    Write-Host "  [版本探測] 找到檔案: $file" -ForegroundColor DarkGray
                    $content = Get-Content -Path $file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if (-not [string]::IsNullOrWhiteSpace($content)) {
                        # 1. 優先嘗試組合 APP_VERSION_MAJOR / MINOR / MAINTENANCE / BUILD
                        $major = if ($content -match '(?m)^\s*APP_VERSION_MAJOR\s*=\s*([0-9]+)') { $matches[1].Trim() } else { $null }
                        $minor = if ($content -match '(?m)^\s*APP_VERSION_MINOR\s*=\s*([0-9]+)') { $matches[1].Trim() } else { $null }
                        $maint = if ($content -match '(?m)^\s*APP_VERSION_(?:MAINTENANCE|PATCH)\s*=\s*([0-9]+)') { $matches[1].Trim() } else { $null }
                        $build = if ($content -match '(?m)^\s*APP_VERSION_BUILD\s*=\s*([0-9]+)') { $matches[1].Trim() } else { $null }

                        if ($major -and $minor) {
                            $verParts = @($major, $minor)
                            if ($maint) { $verParts += $maint }
                            if ($build) { $verParts += $build }
                            $extractedVersion = $verParts -join '.'
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [qt-qmake] APP_VERSION 變數從 [$(Split-Path $file -Leaf)] 成功組合: $extractedVersion" -ForegroundColor Green
                            break
                        }

                        # 2. 嘗試通用 VERSION_MAJOR / MINOR / MAINTENANCE / BUILD
                        $major = if ($content -match '(?m)^\s*VERSION_MAJOR\s*=\s*([0-9]+)') { $matches[1].Trim() } else { $null }
                        $minor = if ($content -match '(?m)^\s*VERSION_MINOR\s*=\s*([0-9]+)') { $matches[1].Trim() } else { $null }
                        $maint = if ($content -match '(?m)^\s*VERSION_(?:MAINTENANCE|PATCH)\s*=\s*([0-9]+)') { $matches[1].Trim() } else { $null }
                        $build = if ($content -match '(?m)^\s*VERSION_BUILD\s*=\s*([0-9]+)') { $matches[1].Trim() } else { $null }

                        if ($major -and $minor) {
                            $verParts = @($major, $minor)
                            if ($maint) { $verParts += $maint }
                            if ($build) { $verParts += $build }
                            $extractedVersion = $verParts -join '.'
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [qt-qmake] VERSION 變數從 [$(Split-Path $file -Leaf)] 成功組合: $extractedVersion" -ForegroundColor Green
                            break
                        }

                        # 3. 嘗試單行 VERSION = x.y.z 或 APP_VERSION = x.y.z
                        if ($content -match '(?m)^\s*(?:APP_VERSION|VERSION)\s*=\s*([0-9\.]+)') {
                            $extractedVersion = $matches[1].Trim()
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [qt-qmake] 單行 VERSION 從 [$(Split-Path $file -Leaf)] 成功解析: $extractedVersion" -ForegroundColor Green
                            break
                        }
                    }
                } else {
                    Write-Host "  [版本探測] (略過) 檔案不存在: $file" -ForegroundColor DarkGray
                }
            }
        }

        { $_ -in @("file", "plain-file") } {
            Write-Host "  [版本探測] 專案 [$projName] 開始讀取純文字版本檔案..." -ForegroundColor Cyan

            $rawCandidates = @()
            if (-not [string]::IsNullOrWhiteSpace($versionFile)) {
                $rawCandidates += (Join-Path $ProjectRoot $versionFile)
            } else {
                # A. 優先檢查專案掛載路徑
                if ($ProjectConfig.paths) {
                    foreach ($p in $ProjectConfig.paths) {
                        $cleanP = $p.Replace('/', '\').TrimStart('\')
                        if ($cleanP -like "*VERSION*" -or $cleanP -like "*version*") {
                            $rawCandidates += (Join-Path $ProjectRoot $cleanP)
                        } else {
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\VERSION")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\version.txt")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\VERSION.txt")
                        }
                    }
                }
                # B. 檢查專案根目錄
                $rawCandidates += @(
                    (Join-Path $ProjectRoot "VERSION"),
                    (Join-Path $ProjectRoot "version.txt"),
                    (Join-Path $ProjectRoot "VERSION.txt")
                )
            }

            $targetFiles = @($rawCandidates | Select-Object -Unique)

            foreach ($file in $targetFiles) {
                if (Test-Path $file) {
                    Write-Host "  [版本探測] 找到檔案: $file" -ForegroundColor DarkGray
                    $content = Get-Content -Path $file -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue
                    if (-not [string]::IsNullOrWhiteSpace($content)) {
                        $extractedVersion = $content.Trim()
                        Write-Host "  [版本萃取] 專案 [$projName] 依據 [file] 從 [$(Split-Path $file -Leaf)] 成功讀取: $extractedVersion" -ForegroundColor Green
                        break
                    }
                } else {
                    Write-Host "  [版本探測] (略過) 檔案不存在: $file" -ForegroundColor DarkGray
                }
            }
        }

        { $_ -in @("qt-cmake", "cmake") } {
            Write-Host "  [版本探測] 專案 [$projName] 開始搜尋 CMakeLists.txt 版本定義..." -ForegroundColor Cyan

            $rawCandidates = @()
            if (-not [string]::IsNullOrWhiteSpace($versionFile)) {
                $rawCandidates += (Join-Path $ProjectRoot $versionFile)
            } else {
                # A. 優先檢查專案掛載路徑
                if ($ProjectConfig.paths) {
                    foreach ($p in $ProjectConfig.paths) {
                        $cleanP = $p.Replace('/', '\').TrimStart('\')
                        if ($cleanP -like "*CMakeLists.txt") {
                            $rawCandidates += (Join-Path $ProjectRoot $cleanP)
                        } else {
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\CMakeLists.txt")
                        }
                    }
                }
                # B. 檢查專案根目錄
                $rawCandidates += (Join-Path $ProjectRoot "CMakeLists.txt")
            }

            $targetFiles = @($rawCandidates | Select-Object -Unique)

            foreach ($file in $targetFiles) {
                if (Test-Path $file) {
                    Write-Host "  [版本探測] 找到檔案: $file" -ForegroundColor DarkGray
                    $content = Get-Content -Path $file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if (-not [string]::IsNullOrWhiteSpace($content)) {
                        # 1. 優先嘗試組合 set(APP_VERSION_MAJOR 4) / MINOR / BUILD / PATCH
                        $major = if ($content -match '(?mi)^\s*set\s*\(\s*APP_VERSION_MAJOR\s+([0-9]+)\s*\)') { $matches[1].Trim() } else { $null }
                        $minor = if ($content -match '(?mi)^\s*set\s*\(\s*APP_VERSION_MINOR\s+([0-9]+)\s*\)') { $matches[1].Trim() } else { $null }
                        $build = if ($content -match '(?mi)^\s*set\s*\(\s*APP_VERSION_(?:BUILD|PATCH|MAINTENANCE)\s+([0-9]+)\s*\)') { $matches[1].Trim() } else { $null }

                        if ($major -and $minor) {
                            $verParts = @($major, $minor)
                            if ($build) { $verParts += $build }
                            $extractedVersion = $verParts -join '.'
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [qt-cmake] APP_VERSION 變數從 [$(Split-Path $file -Leaf)] 成功組合: $extractedVersion" -ForegroundColor Green
                            break
                        }

                        # 2. 嘗試通用 set(VERSION_MAJOR 4) 或 set(PROJECT_VERSION_MAJOR 4)
                        $major = if ($content -match '(?mi)^\s*set\s*\(\s*(?:PROJECT_)?VERSION_MAJOR\s+([0-9]+)\s*\)') { $matches[1].Trim() } else { $null }
                        $minor = if ($content -match '(?mi)^\s*set\s*\(\s*(?:PROJECT_)?VERSION_MINOR\s+([0-9]+)\s*\)') { $matches[1].Trim() } else { $null }
                        $build = if ($content -match '(?mi)^\s*set\s*\(\s*(?:PROJECT_)?VERSION_(?:BUILD|PATCH|MAINTENANCE)\s+([0-9]+)\s*\)') { $matches[1].Trim() } else { $null }

                        if ($major -and $minor) {
                            $verParts = @($major, $minor)
                            if ($build) { $verParts += $build }
                            $extractedVersion = $verParts -join '.'
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [qt-cmake] VERSION 變數從 [$(Split-Path $file -Leaf)] 成功組合: $extractedVersion" -ForegroundColor Green
                            break
                        }

                        # 3. 嘗試 project(... VERSION 4.0.9 ...) 直接定義數字
                        if ($content -match '(?s)project\s*\([^)]*VERSION\s+([0-9\.]+)') {
                            $extractedVersion = $matches[1].Trim()
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [qt-cmake] project(VERSION) 從 [$(Split-Path $file -Leaf)] 成功解析: $extractedVersion" -ForegroundColor Green
                            break
                        }

                        # 4. 嘗試單行 set(PROJECT_VERSION "4.0.9") 或 set(APP_VERSION "4.0.9")
                        if ($content -match '(?mi)^\s*set\s*\(\s*(?:PROJECT_VERSION|APP_VERSION|VERSION)\s+["'']?([0-9\.]+)["'']?\s*\)') {
                            $extractedVersion = $matches[1].Trim()
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [qt-cmake] set(VERSION) 從 [$(Split-Path $file -Leaf)] 成功解析: $extractedVersion" -ForegroundColor Green
                            break
                        }
                    }
                } else {
                    Write-Host "  [版本探測] (略過) 檔案不存在: $file" -ForegroundColor DarkGray
                }
            }
        }

        { $_ -in @("ios", "xcode", "apple", "macos-app") } {
            Write-Host "  [版本探測] 專案 [$projName] 開始搜尋 iOS / Xcode 版本定義..." -ForegroundColor Cyan

            $rawCandidates = @()
            if (-not [string]::IsNullOrWhiteSpace($versionFile)) {
                $rawCandidates += (Join-Path $ProjectRoot $versionFile)
            } else {
                # A. 優先檢查專案掛載路徑
                if ($ProjectConfig.paths) {
                    foreach ($p in $ProjectConfig.paths) {
                        $cleanP = $p.Replace('/', '\').TrimStart('\')
                        if ($cleanP -like "*.pbxproj" -or $cleanP -like "*.plist" -or $cleanP -like "*.xcconfig" -or $cleanP -like "*.podspec") {
                            $rawCandidates += (Join-Path $ProjectRoot $cleanP)
                        } else {
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\*.xcodeproj\project.pbxproj")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\project.pbxproj")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\Info.plist")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\*.xcconfig")
                            $rawCandidates += (Join-Path $ProjectRoot "$cleanP\*.podspec")
                        }
                    }
                }
                # B. 檢查專案根目錄
                $rawCandidates += @(
                    (Join-Path $ProjectRoot "*.xcodeproj\project.pbxproj"),
                    (Join-Path $ProjectRoot "Info.plist"),
                    (Join-Path $ProjectRoot "*.xcconfig"),
                    (Join-Path $ProjectRoot "*.podspec")
                )
            }

            # 展開萬用字元候選項目
            $targetFiles = @()
            foreach ($cand in $rawCandidates) {
                if ($cand -like "*[*?]*") {
                    $matched = Get-ChildItem -Path $cand -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
                    if ($matched) { $targetFiles += $matched }
                } else {
                    $targetFiles += $cand
                }
            }
            $targetFiles = @($targetFiles | Select-Object -Unique)

            foreach ($file in $targetFiles) {
                if (Test-Path $file) {
                    Write-Host "  [版本探測] 找到檔案: $file" -ForegroundColor DarkGray
                    $content = Get-Content -Path $file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    if (-not [string]::IsNullOrWhiteSpace($content)) {
                        # 1. 嘗試 project.pbxproj 或 .xcconfig 中的 MARKETING_VERSION
                        if ($content -match '(?m)^\s*MARKETING_VERSION\s*=\s*([0-9\.]+)\s*;?') {
                            $extractedVersion = $matches[1].Trim()
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [ios] MARKETING_VERSION 從 [$(Split-Path $file -Leaf)] 成功解析: $extractedVersion" -ForegroundColor Green
                            break
                        }

                        # 2. 嘗試 Info.plist 中的 CFBundleShortVersionString
                        if ($content -match '(?s)<key>CFBundleShortVersionString</key>\s*<string>([0-9\.]+)</string>') {
                            $extractedVersion = $matches[1].Trim()
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [ios] Info.plist 從 [$(Split-Path $file -Leaf)] 成功解析: $extractedVersion" -ForegroundColor Green
                            break
                        }

                        # 3. 嘗試 CocoaPods podspec 中的 s.version
                        if ($content -match '(?m)^\s*(?:s|spec)\.version\s*=\s*["'']([0-9\.]+)["'']') {
                            $extractedVersion = $matches[1].Trim()
                            Write-Host "  [版本萃取] 專案 [$projName] 依據 [ios] podspec 從 [$(Split-Path $file -Leaf)] 成功解析: $extractedVersion" -ForegroundColor Green
                            break
                        }
                    }
                } else {
                    Write-Host "  [版本探測] (略過) 檔案不存在: $file" -ForegroundColor DarkGray
                }
            }
        }

        default {
            Write-Warning "  [版本萃取] 尚未支援的 versionRule: '$rule'，將採用預設版本。"
        }
    }

    # 4. Fallback 處理
    if ([string]::IsNullOrWhiteSpace($extractedVersion)) {
        if (-not [string]::IsNullOrWhiteSpace($DefaultVersionTag)) {
            Write-Host "  [版本萃取] 專案 [$projName] 規則 [$rule] 未解析出版本，Fallback 採用全域 VersionTag: $DefaultVersionTag" -ForegroundColor Yellow
            return $DefaultVersionTag
        }
        $fallbackDate = (Get-Date -Format "yyyy.MM.dd")
        Write-Host "  [版本萃取] 專案 [$projName] 規則 [$rule] 未解析出版本且無全域標籤，保底採用當前日期: $fallbackDate" -ForegroundColor Yellow
        return $fallbackDate
    }

    return $extractedVersion
}
