@echo off
chcp 65001 >nul
where py >nul 2>nul
if errorlevel 1 (
  echo 请先从 https://www.python.org/downloads/windows/ 安装 Python 3.10 或更新版本。
  exit /b 1
)
py -3 "%~dp0klburn-builder.py" %*
exit /b %errorlevel%
