@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo.
echo ========================================
echo   新手没有 Mac：打开手把手教程
echo ========================================
echo.
if exist "%~dp0新手无Mac手把手.txt" (
  start "" notepad "%~dp0新手无Mac手把手.txt"
) else if exist "%~dp0无Mac打包详解.txt" (
  start "" notepad "%~dp0无Mac打包详解.txt"
)
echo  已用记事本打开教程，请从第 1 章按顺序做。
echo.
pause
