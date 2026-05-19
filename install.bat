@echo off
REM MCP FairyGUI 快速安装脚本

echo ========================================
echo   MCP FairyGUI 安装脚本
echo ========================================
echo.

REM 检查 Python
python --version >nul 2>&1
if errorlevel 1 (
    echo [错误] 未找到 Python，请先安装 Python 3.10+
    pause
    exit /b 1
)

echo [1/3] 安装 MCP 服务依赖...
cd /d "%~dp0"
pip install -e . --quiet

if errorlevel 1 (
    echo [错误] 安装依赖失败
    pause
    exit /b 1
)

echo [2/3] 创建通信目录...
if not exist "plugin\MCPBridge\bridge\commands" mkdir "plugin\MCPBridge\bridge\commands"
if not exist "plugin\MCPBridge\bridge\results" mkdir "plugin\MCPBridge\bridge\results"
if not exist "plugin\MCPBridge\bridge\screenshots" mkdir "plugin\MCPBridge\bridge\screenshots"

echo [3/3] 验证安装...
python -c "import mcp_fairygui; print('MCP 服务安装成功!')"

echo.
echo ========================================
echo   安装完成!
echo ========================================
echo.
echo 下一步:
echo 1. 将 plugin\MCPBridge 复制到你的 FairyGUI 项目的 plugins 目录
echo 2. 打开 FairyGUI 编辑器 (确认插件已加载)
echo 3. 配置 MCP 客户端 (参考 README.md)
echo 4. 调用 fg_editor_status 测试连接
echo.
pause
