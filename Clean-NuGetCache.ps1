<#
.SYNOPSIS
    NuGet Global Packages Cache Cleaner (Smart Path Edition)
.DESCRIPTION
    Scans for NuGet global package cache (%USERPROFILE%\.nuget\packages)
    and HTTP v3 cache (%LOCALAPPDATA%\NuGet\v3-cache) for packages older than
    a specific threshold and removes them to reclaim disk space.
.NOTES
    Author: Dolphin (feat. Brigette Aurora)
    Target: .NET & C# / C++ Development Environments
#>

param (
    [int]$DaysRetention = 30,  # Retention period in days (0 for all)
    [switch]$Force = $false    # Default is False (Dry Run), specify -Force to execute deletion
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "      NuGet Cache Cleaner by Brigette     " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# 1. Process check
$RunningProcesses = Get-Process -Name "devenv", "dotnet", "MSBuild", "rider64" -ErrorAction SilentlyContinue
if ($RunningProcesses) {
    $ProcessNames = ($RunningProcesses | Select-Object -ExpandProperty ProcessName -Unique) -join ", "
    Write-Host "[Warning] Active build/IDE process detected: $ProcessNames" -ForegroundColor Yellow
    Write-Host "          Package files might be locked during active builds." -ForegroundColor DarkGray
    Write-Host "          For best results, finish active builds before performing cleanup.`n" -ForegroundColor DarkGray
}

$CutoffDate = (Get-Date).AddDays(-$DaysRetention)
if ($DaysRetention -eq 0) {
    Write-Host "Retention: All package versions targeted (Retention = 0 days)`n" -ForegroundColor Gray
} else {
    Write-Host "Targeting packages older than: $($CutoffDate.ToString('yyyy-MM-dd')) ($DaysRetention days retention)`n" -ForegroundColor Gray
}

$Candidates = [System.Collections.Generic.List[PSCustomObject]]::new()

# 2. Target A: Global Packages Cache (%USERPROFILE%\.nuget\packages)
$PackagesPath = Join-Path $env:USERPROFILE ".nuget\packages"
if (Test-Path $PackagesPath) {
    $PackageDirs = Get-ChildItem -Path $PackagesPath -Directory -ErrorAction SilentlyContinue
    foreach ($PkgDir in $PackageDirs) {
        $VersionDirs = Get-ChildItem -Path $PkgDir.FullName -Directory -ErrorAction SilentlyContinue
        foreach ($VerDir in $VersionDirs) {
            if ($VerDir.LastWriteTime -lt $CutoffDate) {
                $Files = Get-ChildItem -Path $VerDir.FullName -Recurse -File -ErrorAction SilentlyContinue
                $Size = ($Files | Measure-Object -Property Length -Sum).Sum
                if ($null -eq $Size) { $Size = 0 }

                $Candidates.Add([PSCustomObject]@{
                    Scope        = "Global Package"
                    Package      = $PkgDir.Name
                    Version      = $VerDir.Name
                    LastModified = $VerDir.LastWriteTime
                    SizeBytes    = $Size
                    Path         = $VerDir.FullName
                })
            }
        }
    }
}

# 3. Target B: HTTP v3 Cache (%LOCALAPPDATA%\NuGet\v3-cache)
$HttpCachePath = Join-Path $env:LOCALAPPDATA "NuGet\v3-cache"
if (Test-Path $HttpCachePath) {
    Get-ChildItem -Path $HttpCachePath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $File = $_
        if ($File.LastWriteTime -lt $CutoffDate) {
            $Candidates.Add([PSCustomObject]@{
                Scope        = "HTTP v3 Cache"
                Package      = "v3-cache"
                Version      = $File.Name
                LastModified = $File.LastWriteTime
                SizeBytes    = $File.Length
                Path         = $File.FullName
            })
        }
    }
}

if ($Candidates.Count -eq 0) {
    Write-Host "Excellent! No stale NuGet packages or cache found matching criteria." -ForegroundColor Green
    exit
}

# 4. Reporting Stats
$TotalSize = ($Candidates | Measure-Object -Property SizeBytes -Sum).Sum
$TotalSizeFormatted = if ($TotalSize -ge 1GB) { "{0:N2} GB" -f ($TotalSize / 1GB) } else { "{0:N2} MB" -f ($TotalSize / 1MB) }

Write-Host "Found $($Candidates.Count) package version(s)/cache items. Total Potential Reclaim: $TotalSizeFormatted" -ForegroundColor Yellow

# 5. Execution Logic
if ($Force) {
    $SuccessCount = 0
    $FailCount = 0
    
    foreach ($Item in $Candidates) {
        $SizeText = if ($Item.SizeBytes -ge 1GB) { "{0:N2} GB" -f ($Item.SizeBytes / 1GB) } else { "{0:N2} MB" -f ($Item.SizeBytes / 1MB) }
        Write-Host "Deleting [$($Item.Package)@$($Item.Version)] ($SizeText)..." -NoNewline
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
    Write-Host "`n[Dry Run Result] The following package versions would be deleted:" -ForegroundColor Magenta
    $Candidates | Select-Object Scope, Package, Version, @{N='Size (MB)';E={"{0:N2}" -f ($_.SizeBytes / 1MB)}}, LastModified | Format-Table -AutoSize
    
    # 6. Action Options
    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "Action Options:" -ForegroundColor White
    Write-Host "  1. Execute above deletion:" -ForegroundColor Gray
    Write-Host "     .\Clean-NuGetCache.ps1 -Force" -ForegroundColor Cyan
    Write-Host "  2. Clean all package versions regardless of age (Retention = 0):" -ForegroundColor Gray
    Write-Host "     .\Clean-NuGetCache.ps1 -DaysRetention 0 -Force" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray
}
