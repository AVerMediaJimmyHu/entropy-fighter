<#
.SYNOPSIS
    JetBrains & Android Studio Cache Cleaner (Smart Path Edition)
.DESCRIPTION
    Scans for JetBrains IDEs (IntelliJ IDEA, CLion, PyCharm, Rider, WebStorm, etc.)
    and Google Android Studio caches. Supports retention-based cache pruning and
    full orphan/legacy IDE version purging.
.NOTES
    Author: Dolphin (feat. Brigette Aurora)
    Target: JetBrains & Android Studio Development Environments
#>

param (
    [int]$DaysRetention = 30,           # Retention period in days for active IDE caches (0 for all)
    [switch]$PurgeOldVersions = $false, # When enabled, completely deletes obsolete/legacy IDE directories
    [switch]$Force = $false             # Default is False (Dry Run), specify -Force to execute deletion
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   JetBrains Cache Cleaner by Brigette    " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Process running check
$IDEProcesses = @(
    "idea64", "studio64", "clion64", "pycharm64", "rider64",
    "webstorm64", "goland64", "rustrover64", "datagrip64",
    "phpstorm64", "fsnotifier", "fsnotifier64"
)
$RunningProcesses = Get-Process -Name $IDEProcesses -ErrorAction SilentlyContinue
if ($RunningProcesses) {
    $ProcessNames = ($RunningProcesses | Select-Object -ExpandProperty ProcessName -Unique) -join ", "
    Write-Host "[Warning] Active IDE process detected: $ProcessNames" -ForegroundColor Yellow
    Write-Host "          Active workspace indexes might be locked or will immediately re-index." -ForegroundColor DarkGray
    Write-Host "          For best results, close IDEs before performing cleanup.`n" -ForegroundColor DarkGray
}

# 2. Scan Locations
$SearchBases = @()

$JetBrainsBase = Join-Path $env:LOCALAPPDATA "JetBrains"
if (Test-Path $JetBrainsBase) {
    $SearchBases += [PSCustomObject]@{
        Name   = "JetBrains"
        Path   = $JetBrainsBase
        Filter = "*"
    }
}

$GoogleBase = Join-Path $env:LOCALAPPDATA "Google"
if (Test-Path $GoogleBase) {
    $SearchBases += [PSCustomObject]@{
        Name   = "Android Studio"
        Path   = $GoogleBase
        Filter = "AndroidStudio*"
    }
}

if ($SearchBases.Count -eq 0) {
    Write-Host "[Error] No JetBrains or Android Studio installation paths found." -ForegroundColor Red
    exit
}

# 3. Product & Version Grouping
$DiscoveredIDEs = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($Base in $SearchBases) {
    $Dirs = Get-ChildItem -Path $Base.Path -Directory -Filter $Base.Filter -ErrorAction SilentlyContinue
    foreach ($Dir in $Dirs) {
        # Match product name and version (e.g. IntelliJIdea2025.3, AndroidStudio2026.1.2)
        if ($Dir.Name -match '^([a-zA-Z]+)(\d{4}(?:\.\d+)*.*)$') {
            $ProductName = $Matches[1]
            $VersionStr  = $Matches[2]
            
            # Attempt to parse System.Version for accurate semantic sorting
            $ParsedVersion = $null
            $CleanVersionStr = ($VersionStr -replace '[^\d\.]', '').TrimEnd('.')
            try {
                $ParsedVersion = [System.Version]$CleanVersionStr
            } catch {
                $ParsedVersion = [System.Version]"0.0"
            }

            $DiscoveredIDEs.Add([PSCustomObject]@{
                DirName       = $Dir.Name
                Directory     = $Dir
                ProductName   = $ProductName
                VersionStr    = $VersionStr
                ParsedVersion = $ParsedVersion
                LastModified  = $Dir.LastWriteTime
                IsActive      = $false
            })
        }
    }
}

if ($DiscoveredIDEs.Count -eq 0) {
    Write-Host "[Error] No versioned JetBrains/Android Studio directories found." -ForegroundColor Red
    exit
}

# Determine Active (latest) vs Legacy (older) versions per product
$UniqueProducts = $DiscoveredIDEs | Select-Object -ExpandProperty ProductName -Unique
foreach ($Prod in $UniqueProducts) {
    $ProductIDEs = @($DiscoveredIDEs | Where-Object { $_.ProductName -eq $Prod } | Sort-Object -Property ParsedVersion, LastModified -Descending)
    if ($ProductIDEs.Count -gt 0) {
        $ProductIDEs[0].IsActive = $true  # Highest version is active
    }
}

# Display IDE Inventory
Write-Host "Detected IDE Installations:" -ForegroundColor White
foreach ($Ide in $DiscoveredIDEs) {
    $StatusLabel = if ($Ide.IsActive) { "[Active / Latest]" } else { "[Legacy / Orphan]" }
    $StatusColor = if ($Ide.IsActive) { "Green" } else { "Yellow" }
    Write-Host "  - $($Ide.DirName) " -NoNewline
    Write-Host $StatusLabel -ForegroundColor $StatusColor -NoNewline
    Write-Host " (Last accessed: $($Ide.LastModified.ToString('yyyy-MM-dd')))" -ForegroundColor DarkGray
}
Write-Host ""

# 4. Target Collection
$CutoffDate = (Get-Date).AddDays(-$DaysRetention)
$TargetFolders = @(
    "caches", "index", "compile-server", "compiler",
    "log", "tmp", "jcef_cache", "projects", "testHistory",
    "gmaven.index", "maven.google"
)

$Candidates = [System.Collections.Generic.List[PSCustomObject]]::new()
$LegacyIDEsFound = @($DiscoveredIDEs | Where-Object { -not $_.IsActive })

foreach ($Ide in $DiscoveredIDEs) {
    if (-not $Ide.IsActive -and $PurgeOldVersions) {
        # Purge entire legacy IDE folder
        $Files = Get-ChildItem -Path $Ide.Directory.FullName -Recurse -File -ErrorAction SilentlyContinue
        $Size = ($Files | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $Size) { $Size = 0 }

        $Candidates.Add([PSCustomObject]@{
            Product      = $Ide.DirName
            Category     = "[Full Legacy Directory]"
            LastModified = $Ide.Directory.LastWriteTime
            SizeBytes    = $Size
            Path         = $Ide.Directory.FullName
        })
    } else {
        # Scan standard cache folders within the IDE directory
        foreach ($TargetName in $TargetFolders) {
            $TargetDir = Join-Path $Ide.Directory.FullName $TargetName
            if (Test-Path $TargetDir) {
                $DirInfo = Get-Item -Path $TargetDir
                if ($DirInfo.LastWriteTime -lt $CutoffDate) {
                    $Files = Get-ChildItem -Path $TargetDir -Recurse -File -ErrorAction SilentlyContinue
                    $Size = ($Files | Measure-Object -Property Length -Sum).Sum
                    if ($null -eq $Size) { $Size = 0 }

                    $Candidates.Add([PSCustomObject]@{
                        Product      = $Ide.DirName
                        Category     = $TargetName
                        LastModified = $DirInfo.LastWriteTime
                        SizeBytes    = $Size
                        Path         = $TargetDir
                    })
                }
            }
        }
    }
}

if ($Candidates.Count -eq 0) {
    Write-Host "Excellent! No stale cache or purgeable items found matching your criteria." -ForegroundColor Green
    
    if ($LegacyIDEsFound.Count -gt 0 -and -not $PurgeOldVersions) {
        Write-Host "`n[Notice] Found $($LegacyIDEsFound.Count) legacy IDE version(s). Run with -PurgeOldVersions to remove whole directories." -ForegroundColor Cyan
    }
    exit
}

# 5. Reporting Stats
$TotalSize = ($Candidates | Measure-Object -Property SizeBytes -Sum).Sum
$TotalSizeFormatted = if ($TotalSize -ge 1GB) { "{0:N2} GB" -f ($TotalSize / 1GB) } else { "{0:N2} MB" -f ($TotalSize / 1MB) }

Write-Host "Found $($Candidates.Count) cleanup items. Total Potential Reclaim: $TotalSizeFormatted" -ForegroundColor Yellow

# 6. Execution Logic
if ($Force) {
    $SuccessCount = 0
    $FailCount = 0
    
    foreach ($Item in $Candidates) {
        $SizeText = if ($Item.SizeBytes -ge 1GB) { "{0:N2} GB" -f ($Item.SizeBytes / 1GB) } else { "{0:N2} MB" -f ($Item.SizeBytes / 1MB) }
        Write-Host "Deleting [$($Item.Product)\$($Item.Category)] ($SizeText)..." -NoNewline
        try {
            Remove-Item -Path $Item.Path -Recurse -Force -ErrorAction Stop
            Write-Host " [OK]" -ForegroundColor Green
            $SuccessCount++
        } catch {
            Write-Host " [Failed]" -ForegroundColor Red
            Write-Host "  Error: $_" -ForegroundColor Red
            $FailCount++
        }
    }
    Write-Host "`nCleanup Complete: $SuccessCount deleted, $FailCount failed." -ForegroundColor Cyan
    Write-Host "Total Reclaimed: $TotalSizeFormatted." -ForegroundColor Cyan
} else {
    # Dry Run Output Table
    Write-Host "`n[Dry Run Result] The following targets would be deleted:" -ForegroundColor Magenta
    $Candidates | Select-Object Product, Category, @{N='Size (MB)';E={"{0:N2}" -f ($_.SizeBytes / 1MB)}}, LastModified | Format-Table -AutoSize
    
    # 7. Actionable Next Steps / Guidance
    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "Action Options:" -ForegroundColor White
    Write-Host "  1. Execute above deletion:" -ForegroundColor Gray
    Write-Host "     .\Clean-JetBrainsCache.ps1 -Force" -ForegroundColor Cyan

    if ($LegacyIDEsFound.Count -gt 0) {
        if (-not $PurgeOldVersions) {
            Write-Host "  2. Purge entire legacy IDE versions ($($LegacyIDEsFound.DirName -join ', ')):" -ForegroundColor Gray
            Write-Host "     .\Clean-JetBrainsCache.ps1 -PurgeOldVersions -Force" -ForegroundColor Cyan
        }
    }
    
    Write-Host "  3. Clean all caches regardless of age (Retention = 0):" -ForegroundColor Gray
    Write-Host "     .\Clean-JetBrainsCache.ps1 -DaysRetention 0 -Force" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray
}
