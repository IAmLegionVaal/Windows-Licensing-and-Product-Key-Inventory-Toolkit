@echo off
setlocal
cd /d "%~dp0"

:menu
set "ACTION="
cls
echo ============================================================
echo   WINDOWS LICENSING AND PRODUCT KEY TOOLKIT
echo ============================================================
echo   1. Diagnose licensing state
echo   2. Run safe licensing repair
echo   3. Restart licensing services
echo   4. Reinstall Windows licence files
echo   5. Request online activation
echo   6. Run DISM RestoreHealth
echo   7. Run System File Checker
echo   8. Open Activation Settings
echo   9. Export full OEM firmware key
echo   0. Exit
echo ============================================================
set /p CHOICE=Select an option: 

if "%CHOICE%"=="1" set "ACTION=Diagnose"
if "%CHOICE%"=="2" set "ACTION=RepairAllSafe"
if "%CHOICE%"=="3" set "ACTION=RestartLicensingServices"
if "%CHOICE%"=="4" set "ACTION=ReinstallLicenseFiles"
if "%CHOICE%"=="5" set "ACTION=AttemptActivation"
if "%CHOICE%"=="6" set "ACTION=RunDISM"
if "%CHOICE%"=="7" set "ACTION=RunSFC"
if "%CHOICE%"=="8" set "ACTION=OpenActivationSettings"
if "%CHOICE%"=="9" set "ACTION=ExportFullOemKey"
if "%CHOICE%"=="0" goto end
if not defined ACTION goto menu

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Windows_Licensing_Product_Key_Toolkit.ps1" -Action "%ACTION%"
echo.
pause
goto menu

:end
endlocal
