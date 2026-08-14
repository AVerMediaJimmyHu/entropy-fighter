<#
.SYNOPSIS
    Qt Creator & Clangd Cache Cleaner (Smart Path Edition)
.DESCRIPTION
    Scans for Qt Creator and Clangd index caches older than a specific threshold
    (including Clangd AST/symbol indexes, QML caches, and temporary logs)
    and removes them to reclaim disk space.
.NOTES
    Author: Dolphin (feat. Brigette Aurora)
    Target: Qt Creator & C++ Development Environments
#>

param (
    [int]$DaysRetention = 30,  # Retention period in days (0 for all)
    [switch]$Force = $false    # Default is False (Dry Run), specify -Force to execute deletion
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Qt Creator & Clangd Cleaner by Brigette" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Process running check
$RunningProcesses = Get-Process -Name "qtcreator", "clangd" -ErrorAction SilentlyContinue
if ($RunningProcesses) {
    $ProcessNames = ($RunningProcesses | Select-Object -ExpandProperty ProcessName -Unique) -join ", "
    Write-Host "[Warning] Active process detected: $ProcessNames" -ForegroundColor Yellow
    Write-Host "          Clangd symbol index or Qt cache files might be locked." -ForegroundColor DarkGray
    Write-Host "          For best results, close Qt Creator before performing cleanup.`n" -ForegroundColor DarkGray
}

$CutoffDate = (Get-Date).AddDays(-$DaysRetention)
if ($DaysRetention -eq 0) {
    Write-Host "Retention: All caches targeted (Retention = 0 days)`n" -ForegroundColor Gray
} else {
    Write-Host "Targeting caches older than: $($CutoffDate.ToString('yyyy-MM-dd')) ($DaysRetention days retention)`n" -ForegroundColor Gray
}

$Candidates = [System.Collections.Generic.List[PSCustomObject]]::new()

# 2. Target A: Clangd Global Index (%LOCALAPPDATA%\clangd\index)
$ClangdIndexPath = Join-Path $env:LOCALAPPDATA "clangd\index"
if (Test-Path $ClangdIndexPath) {
    Get-ChildItem -Path $ClangdIndexPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $File = $_
        if ($File.LastWriteTime -lt $CutoffDate) {
            $Candidates.Add([PSCustomObject]@{
                Scope        = "Clangd Index"
                Name         = $File.Name
                LastModified = $File.LastWriteTime
                SizeBytes    = $File.Length
                Path         = $File.FullName
                IsDirectory  = $false
            })
        }
    }
}

# 3. Target B: Qt Creator Local Cache (%LOCALAPPDATA%\QtProject\QtCreator)
$QtLocalPath = Join-Path $env:LOCALAPPDATA "QtProject\QtCreator"
if (Test-Path $QtLocalPath) {
    Get-ChildItem -Path $QtLocalPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $Dir = $_
        if ($Dir.LastWriteTime -lt $CutoffDate) {
            $Files = Get-ChildItem -Path $Dir.FullName -Recurse -File -ErrorAction SilentlyContinue
            $Size = ($Files | Measure-Object -Property Length -Sum).Sum
            if ($null -eq $Size) { $Size = 0 }

            $Candidates.Add([PSCustomObject]@{
                Scope        = "QtCreator Local"
                Name         = $Dir.Name
                LastModified = $Dir.LastWriteTime
                SizeBytes    = $Size
                Path         = $Dir.FullName
                IsDirectory  = $true
            })
        }
    }
}

# 4. Target C: Qt Creator Roaming Logs & Dumps (%APPDATA%\QtProject\qtcreator)
$QtRoamingPath = Join-Path $env:APPDATA "QtProject\qtcreator"
if (Test-Path $QtRoamingPath) {
    # Scan log and crash dump files safely without touching settings (e.g. .ini, .db)
    $LogTargets = @("*.log", "*.dmp", "*.crash", "crashes", "logs")
    foreach ($Pattern in $LogTargets) {
        Get-ChildItem -Path $QtRoamingPath -Filter $Pattern -ErrorAction SilentlyContinue | ForEach-Object {
            $Item = $_
            if ($Item.LastWriteTime -lt $CutoffDate) {
                $Size = if ($Item.PSIsContainer) {
                    (Get-ChildItem -Path $Item.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                } else {
                    $Item.Length
                }
                if ($null -eq $Size) { $Size = 0 }

                $Candidates.Add([PSCustomObject]@{
                    Scope        = "QtCreator Log/Dump"
                    Name         = $Item.Name
                    LastModified = $Item.LastWriteTime
                    SizeBytes    = $Size
                    Path         = $Item.FullName
                    IsDirectory  = $Item.PSIsContainer
                })
            }
        }
    }
}

if ($Candidates.Count -eq 0) {
    Write-Host "Excellent! No stale Qt Creator / Clangd cache found matching criteria." -ForegroundColor Green
    exit
}

# 5. Reporting Stats
$TotalSize = ($Candidates | Measure-Object -Property SizeBytes -Sum).Sum
$TotalSizeFormatted = if ($TotalSize -ge 1GB) { "{0:N2} GB" -f ($TotalSize / 1GB) } else { "{0:N2} MB" -f ($TotalSize / 1MB) }

Write-Host "Found $($Candidates.Count) cache items. Total Potential Reclaim: $TotalSizeFormatted" -ForegroundColor Yellow

# 6. Execution Logic
if ($Force) {
    $SuccessCount = 0
    $FailCount = 0
    
    foreach ($Item in $Candidates) {
        $SizeText = if ($Item.SizeBytes -ge 1GB) { "{0:N2} GB" -f ($Item.SizeBytes / 1GB) } else { "{0:N2} MB" -f ($Item.SizeBytes / 1MB) }
        Write-Host "Deleting [$($Item.Scope)]: $($Item.Name) ($SizeText)..." -NoNewline
        try {
            if ($Item.IsDirectory) {
                Remove-Item -Path $Item.Path -Recurse -Force -ErrorAction Stop
            } else {
                Remove-Item -Path $Item.Path -Force -ErrorAction Stop
            }
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
    $Candidates | Select-Object Scope, Name, @{N='Size (MB)';E={"{0:N2}" -f ($_.SizeBytes / 1MB)}}, LastModified | Format-Table -AutoSize
    
    # 7. Action Options
    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "Action Options:" -ForegroundColor White
    Write-Host "  1. Execute above deletion:" -ForegroundColor Gray
    Write-Host "     .\Clean-QtCreatorCache.ps1 -Force" -ForegroundColor Cyan
    Write-Host "  2. Clean all caches regardless of age (Retention = 0):" -ForegroundColor Gray
    Write-Host "     .\Clean-QtCreatorCache.ps1 -DaysRetention 0 -Force" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray
}
