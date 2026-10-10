@echo off
title Installing Nuvex on Phone...
cd /d "%~dp0"
echo ====================================================
echo Building and installing Nuvex to your connected phone...
echo Device: EUORIRUK4H5HINZ5
echo ====================================================

call "C:\Users\lavish\flutter\bin\flutter.bat" run -d EUORIRUK4H5HINZ5 --no-pub

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ====================================================
    echo Flutter run finished, building APK directly...
    echo ====================================================
    call "C:\Users\lavish\flutter\bin\flutter.bat" build apk --debug --no-pub
    if exist "build\app\outputs\flutter-apk\app-debug.apk" (
        echo.
        echo ====================================================
        echo Installing APK via ADB to EUORIRUK4H5HINZ5...
        echo ====================================================
        "%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" -s EUORIRUK4H5HINZ5 install -r "build\app\outputs\flutter-apk\app-debug.apk"
        echo.
        echo Starting Nuvex on your phone...
        "%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe" -s EUORIRUK4H5HINZ5 shell am start -n com.example.nuvex/com.example.nuvex.MainActivity
    )
)

echo.
echo ====================================================
echo Finished! Check your phone.
echo ====================================================
pause
