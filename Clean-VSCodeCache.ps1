<#
.SYNOPSIS
    VS Code C/C++ Cache Cleaner (Smart Path Edition)
.DESCRIPTION
    Scans for VS Code C/C++ extension (ms-vscode.cpptools) caches older than a specific threshold
    (including IPCH precompiled headers and workspace browse databases) and removes them to reclaim disk space.
.NOTES
    Author: Dolphin (feat. Brigette Aurora)
    Target: VS Code C/C++ Development Environment
#>

param (
    [int]$DaysRetention = 30,  # Retention period in days (0 for all)
    [switch]$Force = $false    # Default is False (Dry Run), specify -Force to execute deletion
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "    VS Code Cache Cleaner by Brigette     " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Configuration & Path Detection
$CppToolsPath = Join-Path $env:LOCALAPPDATA "Microsoft\vscode-cpptools"

# Process running check
$RunningProcesses = Get-Process -Name "Code", "cpptools", "cpptools-srv" -ErrorAction SilentlyContinue
if ($RunningProcesses) {
    Write-Host "[Warning] VS Code or C/C++ IntelliSense process is currently running." -ForegroundColor Yellow
    Write-Host "          Active workspace databases might be locked or will be immediately re-indexed." -ForegroundColor DarkGray
    Write-Host "          For best results, close VS Code before performing cleanup.`n" -ForegroundColor DarkGray
}

# Check directory
if (-not (Test-Path $CppToolsPath)) {
    Write-Host "[Error] VS Code cpptools path not found at:" -ForegroundColor Red
    Write-Host "  $CppToolsPath" -ForegroundColor Red
    Write-Host "No C/C++ cache found on this machine." -ForegroundColor Gray
    exit
}

Write-Host "Target Path: " -NoNewline
Write-Host $CppToolsPath -ForegroundColor Yellow

$CutoffDate = (Get-Date).AddDays(-$DaysRetention)
if ($DaysRetention -eq 0) {
    Write-Host "Retention: All caches targeted (Retention = 0 days)`n" -ForegroundColor Gray
} else {
    Write-Host "Targeting caches older than: $($CutoffDate.ToString('yyyy-MM-dd')) ($DaysRetention days retention)`n" -ForegroundColor Gray
}

# Scan logic
$Candidates = [System.Collections.Generic.List[PSCustomObject]]::new()

# 1. Top-level folders (Project databases)
Get-ChildItem -Path $CppToolsPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "ipch" } | ForEach-Object {
    $Dir = $_
    if ($Dir.LastWriteTime -lt $CutoffDate) {
        $Files = Get-ChildItem -Path $Dir.FullName -Recurse -File -ErrorAction SilentlyContinue
        $Size = ($Files | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $Size) { $Size = 0 }
        
        $Candidates.Add([PSCustomObject]@{
            Type         = "Browse DB"
            Name         = $Dir.Name
            LastModified = $Dir.LastWriteTime
            SizeBytes    = $Size
            Path         = $Dir.FullName
        })
    }
}

# 2. IPCH subfolders
$IpchPath = Join-Path $CppToolsPath "ipch"
if (Test-Path $IpchPath) {
    Get-ChildItem -Path $IpchPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $Dir = $_
        if ($Dir.LastWriteTime -lt $CutoffDate) {
            $Files = Get-ChildItem -Path $Dir.FullName -Recurse -File -ErrorAction SilentlyContinue
            $Size = ($Files | Measure-Object -Property Length -Sum).Sum
            if ($null -eq $Size) { $Size = 0 }
            
            $Candidates.Add([PSCustomObject]@{
                Type         = "IPCH Cache"
                Name         = "ipch\$($Dir.Name)"
                LastModified = $Dir.LastWriteTime
                SizeBytes    = $Size
                Path         = $Dir.FullName
            })
        }
    }
}

if ($Candidates.Count -eq 0) {
    Write-Host "Excellent! No stale VS Code C/C++ cache found matching criteria." -ForegroundColor Green
    exit
}

# Reporting Stats
$TotalSize = ($Candidates | Measure-Object -Property SizeBytes -Sum).Sum
if ($TotalSize -ge 1GB) {
    $TotalSizeFormatted = "{0:N2} GB" -f ($TotalSize / 1GB)
} else {
    $TotalSizeFormatted = "{0:N2} MB" -f ($TotalSize / 1MB)
}

Write-Host "Found $($Candidates.Count) cache items. Total Potential Reclaim: $TotalSizeFormatted" -ForegroundColor Yellow

# Execution Logic
if ($Force) {
    $SuccessCount = 0
    $FailCount = 0
    
    foreach ($Item in $Candidates) {
        $SizeText = if ($Item.SizeBytes -ge 1GB) { "{0:N2} GB" -f ($Item.SizeBytes / 1GB) } else { "{0:N2} MB" -f ($Item.SizeBytes / 1MB) }
        Write-Host "Deleting [$($Item.Type)]: $($Item.Name) ($SizeText)..." -NoNewline
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
    # List mode (Dry Run)
    Write-Host "`n[Dry Run Result] The following items would be deleted:" -ForegroundColor Magenta
    $Candidates | Select-Object Type, Name, @{N='Size (MB)';E={"{0:N2}" -f ($_.SizeBytes / 1MB)}}, LastModified | Format-Table -AutoSize
    
    Write-Host "`nTo actually delete these files, run the script with the -Force switch:" -ForegroundColor Cyan
    Write-Host ".\Clean-VSCodeCache.ps1 -Force" -ForegroundColor White
    Write-Host "Or specify retention period (e.g. 0 days to purge everything):" -ForegroundColor Gray
    Write-Host ".\Clean-VSCodeCache.ps1 -DaysRetention 0 -Force" -ForegroundColor White
}
