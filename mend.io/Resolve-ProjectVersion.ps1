<#
.SYNOPSIS
    Mend.io Automation - Project Version Resolver Module
.DESCRIPTION
    Version: 1.0.0
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
                        $rawCandidates += (Join-Path $ProjectRoot "$p\app\build.gradle.kts")
                        $rawCandidates += (Join-Path $ProjectRoot "$p\app\build.gradle")
                        $rawCandidates += (Join-Path $ProjectRoot "$p\application\build.gradle.kts")
                        $rawCandidates += (Join-Path $ProjectRoot "$p\application\build.gradle")
                        $rawCandidates += (Join-Path $ProjectRoot "$p\build.gradle.kts")
                        $rawCandidates += (Join-Path $ProjectRoot "$p\build.gradle")

                        $rawPropCandidates += (Join-Path $ProjectRoot "$p\gradle.properties")
                        $rawPropCandidates += (Join-Path $ProjectRoot "$p\version.properties")
                        $rawPropCandidates += (Join-Path $ProjectRoot "$p\gradle\libs.versions.toml")
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
