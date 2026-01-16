<#
.SYNOPSIS
    Gradle Wrapper Cleaner (Smart Path Edition)
.DESCRIPTION
    Scans for Gradle wrapper distributions older than a specific threshold
    and removes them to reclaim disk space.
    Respects GRADLE_USER_HOME environment variable.
.NOTES
    Author: Dolphin (feat. Brigette Aurora)
    Target: Modern Android Development Environment
#>

param (
    [int]$DaysRetention = 30,  # 保留最近幾天的檔案
    [switch]$Force = $false    # 預設為 False (Dry Run)，加上 -Force 才會真的刪除
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Gradle Wrapper Cleaner by Brigette     " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Configuration & Path Detection
if (-not [string]::IsNullOrWhiteSpace($env:GRADLE_USER_HOME)) {
    $GradleUserHome = $env:GRADLE_USER_HOME
    $PathSource = "Environment Variable (GRADLE_USER_HOME)"
} else {
    $GradleUserHome = "$env:USERPROFILE\.gradle"
    $PathSource = "Default User Profile"
}

$WrapperDistsPath = Join-Path $GradleUserHome "wrapper\dists"

# Reporting Configuration
Write-Host "Active Gradle Home: " -NoNewline
Write-Host $GradleUserHome -ForegroundColor Yellow
Write-Host "Source: " -NoNewline
Write-Host $PathSource -ForegroundColor DarkGray

if (-not (Test-Path $WrapperDistsPath)) {
    Write-Host "`n[Error] Gradle wrapper path not found at:" -ForegroundColor Red
    Write-Host "  $WrapperDistsPath" -ForegroundColor Red
    Write-Host "Check if you have ever built a project on this machine or if the path is correct." -ForegroundColor Gray
    exit
}

$CutoffDate = (Get-Date).AddDays(-$DaysRetention)
Write-Host "Targeting distributions older than: $($CutoffDate.ToString('yyyy-MM-dd'))`n" -ForegroundColor Gray

# Scan folders
$Candidates = Get-ChildItem -Path $WrapperDistsPath -Directory | ForEach-Object {
    $DirInfo = $_
    # Check the LastWriteTime
    if ($DirInfo.LastWriteTime -lt $CutoffDate) {
        # Calculate size
        $Size = (Get-ChildItem $DirInfo.FullName -Recurse -File | Measure-Object -Property Length -Sum).Sum
        
        [PSCustomObject]@{
            Name = $DirInfo.Name
            LastModified = $DirInfo.LastWriteTime
            SizeBytes = $Size
            Path = $DirInfo.FullName
        }
    }
}

if ($null -eq $Candidates -or $Candidates.Count -eq 0) {
    Write-Host "Excellent! No old Gradle wrappers found in this location." -ForegroundColor Green
    exit
}

# Reporting Stats
$TotalSize = ($Candidates | Measure-Object -Property SizeBytes -Sum).Sum
$TotalSizeMB = "{0:N2} MB" -f ($TotalSize / 1MB)

Write-Host "Found $($Candidates.Count) old versions. Total Potential Reclaim: $TotalSizeMB" -ForegroundColor Yellow

# Execution Logic
if ($Force) {
    foreach ($Item in $Candidates) {
        Write-Host "Deleting: $($Item.Name) ($("{0:N2} MB" -f ($Item.SizeBytes / 1MB)))..." -NoNewline
        try {
            Remove-Item -Path $Item.Path -Recurse -Force -ErrorAction Stop
            Write-Host " [OK]" -ForegroundColor Green
        } catch {
            Write-Host " [Failed]" -ForegroundColor Red
            Write-Host "  Error: $_" -ForegroundColor Red
        }
    }
    Write-Host "`nCleanup Complete. You just reclaimed $TotalSizeMB." -ForegroundColor Cyan
} else {
    # List mode (Dry Run)
    Write-Host "`n[Dry Run Result] The following would be deleted:" -ForegroundColor Magenta
    $Candidates | Select-Object Name, @{N='Size (MB)';E={"{0:N2}" -f ($_.SizeBytes / 1MB)}}, LastModified | Format-Table -AutoSize
    
    Write-Host "`nTo actually delete these files, run the script with the -Force switch:" -ForegroundColor Cyan
    Write-Host ".\Clean-GradleCache.ps1 -Force" -ForegroundColor White
}