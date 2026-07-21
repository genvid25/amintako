@echo off
chcp 65001 >nul
title Установка АминТако
echo Запускаю установку конвейера кадров...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" %*
echo.
pause
