@echo off
setlocal
set "LAUNCHER_DIR=%~dp0"
set "JAR_PATH=%LAUNCHER_DIR%eaglercraft-26.2-java-cli.jar"
if not exist "%JAR_PATH%" set "JAR_PATH=%LAUNCHER_DIR%build\eaglercraft-26.2-java-cli.jar"
if not exist "%JAR_PATH%" (
  echo ERROR: prebuilt patcher JAR is missing beside the GUI launcher 1>&2
  echo Build the patcher on a machine with Java, then copy the JAR here. 1>&2
  exit /b 2
)
if "%EAGLER_PATCHER_JAVA%"=="" set "EAGLER_PATCHER_JAVA=java"
"%EAGLER_PATCHER_JAVA%" -cp "%JAR_PATH%" com.eaglercraft.patcher.GuiMain %*
exit /b %ERRORLEVEL%
