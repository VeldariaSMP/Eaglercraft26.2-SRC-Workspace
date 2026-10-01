@echo off
setlocal
set "LAUNCHER_DIR=%~dp0"
set "PATCHER_JAR=%LAUNCHER_DIR%eaglercraft-26.2-java-cli.jar"
if not exist "%PATCHER_JAR%" set "PATCHER_JAR=%LAUNCHER_DIR%build\eaglercraft-26.2-java-cli.jar"
if not exist "%PATCHER_JAR%" (
  echo ERROR: patcher JAR is missing beside the launcher 1>&2
  exit /b 2
)
if defined EAGLER_PATCHER_JAVA (
  "%EAGLER_PATCHER_JAVA%" -jar "%PATCHER_JAR%" %*
) else (
  java -jar "%PATCHER_JAR%" %*
)
exit /b %ERRORLEVEL%
