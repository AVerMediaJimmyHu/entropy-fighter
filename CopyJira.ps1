<#
.SYNOPSIS
    Entropy Fighter: Clipboard Liberator (FPS Mode)
    Author: Dolphin (feat. Brigette Aurora)
    
.DESCRIPTION
    Bypasses aggressive DLP clipboard restrictions by automating the 
    unlock sequence and logging text to a local file.
    
    [F2]  : Copy & Log (Left hand trigger)
    [F10] : Reset Log
#>

Add-Type -AssemblyName System.Windows.Forms

# --- Win32 API ---
$source = @"
using System;
using System.Runtime.InteropServices;
public class Win32FunctionsFinal
{
    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
try { $API = Add-Type -TypeDefinition $source -PassThru -ErrorAction Stop } catch { }

# ==========================================
# ⚙️ CONFIGURATION (使用者設定區)
# ==========================================

# 1. 觸發熱鍵 (Hex Code)
$Key_Process = 0x71  # F2 = 0x71 (FPS Mode - Recommended)
$Key_Reset   = 0x79  # F10

# 2. DLP 解鎖組合鍵 (SendKeys Syntax)
# ^ = Ctrl, % = Alt, + = Shift
# Example: "^%c" means Ctrl + Alt + C
$UnlockSequence = "^%c" 

# 3. 輸出檔案
$OutputFile  = "$PSScriptRoot\CopiedJira.txt"

# ==========================================

# --- 初始化 ---
if (Test-Path $OutputFile) { Clear-Content $OutputFile } else { New-Item -Path $OutputFile -ItemType File -Force | Out-Null }

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "⚔️ Entropy Fighter: Clipboard Liberator" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Trigger: [F2] | Reset: [F10]" -ForegroundColor Yellow
Write-Host "Unlock Sequence: $UnlockSequence" -ForegroundColor DarkGray
Write-Host "---------------------------------------------"

while ($true) {
    if ($API::GetAsyncKeyState($Key_Process) -eq -32767) {
        
        $browserHandle = $API::GetForegroundWindow()
        
        # 靜默動作
        [System.Windows.Forms.Clipboard]::Clear()

        # 動作序列
        [System.Windows.Forms.SendKeys]::SendWait("^c") # 1. 標準複製
        Start-Sleep -Milliseconds 300
        
        # 2. 發送自定義的解鎖熱鍵
        [System.Windows.Forms.SendKeys]::SendWait($UnlockSequence) 
        
        Start-Sleep -Milliseconds 600

        # --- 處理與顯示 ---
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $text = [System.Windows.Forms.Clipboard]::GetText().Trim()
            $len = $text.Length

            if ($len -gt 0) {
                $text | Out-File -FilePath $OutputFile -Append -Encoding utf8
                
                # 摘要顯示
                $summaryLen = [math]::Min($len, 30)
                $summary = $text.Substring(0, $summaryLen).Replace("`n", " ").Replace("`r", "")
                if ($len -gt 30) { $summary += "..." }

                $time = Get-Date -Format "HH:mm:ss"
                Write-Host "[$time] 🟢 OK ($len) $summary" -ForegroundColor Green
                
                [System.Console]::Beep(1000, 100) 
            } else {
                Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] 🟡 Empty Content" -ForegroundColor Yellow
                [System.Console]::Beep(500, 200)
            }
        } else {
            Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] 🔴 Failed (Blocked)" -ForegroundColor Red
            [System.Console]::Beep(400, 200)
        }
        
        $API::SetForegroundWindow($browserHandle) | Out-Null
        
        Start-Sleep -Milliseconds 400
    }

    if ($API::GetAsyncKeyState($Key_Reset) -eq -32767) {
        try { 
            Clear-Content $OutputFile
            Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] 🟣 Log Reset!" -ForegroundColor Magenta
            [System.Console]::Beep(200, 100) 
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Milliseconds 50
}