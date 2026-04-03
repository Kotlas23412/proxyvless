@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

REM Локальный оркестратор "как в GitHub цепочке":
REM 1) Daily check (python -m lib.vless_checker)
REM 2) Daily Docker check (docker compose build + docker compose run)
REM 3) Опционально MTProto этап (через entrypoint с DOCKER_MTPROTO_ONLY=true)

cd /d "%~dp0"

set "RUN_DAILY=1"
set "RUN_DOCKER=1"
set "RUN_MTPROTO=0"
set "FORCE_SPEEDTEST=1"
set "AUTO_PUSH_CONFIGS=1"
set "CONFIGS_PUSH_BRANCH=main"
set "CONFIGS_COMMIT_PREFIX=chore(configs): auto update from local run"

:parse_args
if "%~1"=="" goto :args_done
if /I "%~1"=="--skip-daily" (
  set "RUN_DAILY=0"
  shift
  goto :parse_args
)
if /I "%~1"=="--skip-docker" (
  set "RUN_DOCKER=0"
  shift
  goto :parse_args
)
if /I "%~1"=="--mtproto" (
  set "RUN_MTPROTO=1"
  shift
  goto :parse_args
)
if /I "%~1"=="--no-speedtest" (
  set "FORCE_SPEEDTEST=0"
  shift
  goto :parse_args
)
if /I "%~1"=="--no-git-push" (
  set "AUTO_PUSH_CONFIGS=0"
  shift
  goto :parse_args
)
if /I "%~1"=="--git-push" (
  set "AUTO_PUSH_CONFIGS=1"
  shift
  goto :parse_args
)
if /I "%~1"=="--help" goto :help
echo [WARNING] Неизвестный аргумент: %~1
shift
goto :parse_args

:args_done
echo ==================================================
echo   GitHub-like local pipeline
echo   RUN_DAILY=%RUN_DAILY%  RUN_DOCKER=%RUN_DOCKER%  RUN_MTPROTO=%RUN_MTPROTO%  FORCE_SPEEDTEST=%FORCE_SPEEDTEST%  AUTO_PUSH_CONFIGS=%AUTO_PUSH_CONFIGS%
echo ==================================================

if not exist ".env" (
  if exist ".env.example" (
    echo [INFO] .env не найден, копирую из .env.example
    copy /Y ".env.example" ".env" >nul
  ) else (
    echo [ERROR] Нет .env и .env.example. Нечего использовать как env.
    exit /b 1
  )
)

call :load_env_value ".env" "AUTO_PUSH_CONFIGS" AUTO_PUSH_CONFIGS
call :load_env_value ".env" "CONFIGS_PUSH_BRANCH" CONFIGS_PUSH_BRANCH
call :load_env_value ".env" "CONFIGS_COMMIT_PREFIX" CONFIGS_COMMIT_PREFIX

if "%RUN_DAILY%"=="1" (
  call :detect_python
  if errorlevel 1 exit /b 1
  call :ensure_requirements
  if errorlevel 1 exit /b 1

  echo.
  echo [PHASE 1/3] Daily check ^(python^)
  !PYTHON_CMD! -m lib.vless_checker
  if errorlevel 1 (
    echo [ERROR] Daily check завершился с ошибкой.
    exit /b 1
  )
)

if "%RUN_DOCKER%"=="1" (
  call :ensure_docker
  if errorlevel 1 exit /b 1

  echo.
  echo [PHASE 2/3] Daily Docker check
  docker compose down --remove-orphans >nul 2>&1
  docker compose build
  if errorlevel 1 (
    echo [ERROR] docker compose build завершился с ошибкой.
    exit /b 1
  )

  set "DOCKER_INPUT="
  if exist "configs\available" (
    for %%I in ("configs\available") do if not "%%~zI"=="0" set "DOCKER_INPUT=configs\available"
  )
  if not defined DOCKER_INPUT (
    if exist "configs\white-list_available" (
      for %%I in ("configs\white-list_available") do if not "%%~zI"=="0" set "DOCKER_INPUT=configs\white-list_available"
    )
  )
  if not defined DOCKER_INPUT (
    echo [ERROR] Не найден непустой входной файл для Docker-этапа ^(configs\available или configs\white-list_available^).
    echo [ERROR] Для эмуляции блокировок ^(iptables/CIDR^) Docker-этап запускается только через stdin.
    exit /b 1
  )

  echo [INFO] Вход Docker-этапа: !DOCKER_INPUT!
  if "%FORCE_SPEEDTEST%"=="1" (
    echo [INFO] Speedtest принудительно включен для Docker-этапа ^(как в daily-check-docker^).
    type "!DOCKER_INPUT!" | docker compose run --rm -T ^
      -e GITHUB_ACTIONS=true ^
      -e OUTPUT_FILE=white-list_available ^
      -e OUTPUT_DIR=configs ^
      -e CIDR_WHITELIST_FILE=/app/cidrlist ^
      -e SPEED_TEST_ENABLED=true ^
      -e SPEED_TEST_OUTPUT=separate_file ^
      vless-checker -
  ) else (
    type "!DOCKER_INPUT!" | docker compose run --rm -T ^
      -e GITHUB_ACTIONS=true ^
      -e OUTPUT_FILE=white-list_available ^
      -e OUTPUT_DIR=configs ^
      -e CIDR_WHITELIST_FILE=/app/cidrlist ^
      vless-checker -
  )
  if errorlevel 1 (
    echo [ERROR] Daily Docker check завершился с ошибкой.
    exit /b 1
  )
)

if "%RUN_MTPROTO%"=="1" (
  call :ensure_docker
  if errorlevel 1 exit /b 1
  echo.
  echo [PHASE 3/3] MTProto check ^(optional^)
  if exist "configs\mtproto" (
    for %%I in ("configs\mtproto") do set "MTSZ=%%~zI"
  ) else (
    set "MTSZ=0"
  )
  if "!MTSZ!"=="0" (
    echo [WARNING] configs\mtproto пуст/отсутствует. Этап MTProto пропущен.
  ) else (
    type "configs\mtproto" | docker compose run --rm -T -e DOCKER_MTPROTO_ONLY=true vless-checker -
    if errorlevel 1 (
      echo [ERROR] MTProto этап завершился с ошибкой.
      exit /b 1
    )
  )
)

echo.
echo [SUCCESS] Pipeline завершен.
echo [INFO] Проверьте файлы в папке configs\
if "%AUTO_PUSH_CONFIGS%"=="1" (
  call :auto_push_configs
)
exit /b 0

:detect_python
where python >nul 2>&1
if not errorlevel 1 (
  set "PYTHON_CMD=python"
  exit /b 0
)
where python3 >nul 2>&1
if not errorlevel 1 (
  set "PYTHON_CMD=python3"
  exit /b 0
)
echo [ERROR] Python не найден. Установите Python 3.10+.
exit /b 1

:ensure_requirements
if not exist "requirements.txt" (
  echo [ERROR] requirements.txt не найден.
  exit /b 1
)
echo [INFO] Установка/проверка Python-зависимостей...
%PYTHON_CMD% -m pip install -r requirements.txt
if errorlevel 1 (
  echo [ERROR] Не удалось установить зависимости.
  exit /b 1
)
exit /b 0

:ensure_docker
where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker не найден.
  exit /b 1
)
docker compose version >nul 2>&1
if errorlevel 1 (
  echo [ERROR] docker compose не найден.
  exit /b 1
)
if not exist "docker-compose.yml" (
  echo [ERROR] docker-compose.yml не найден в текущей папке.
  exit /b 1
)
exit /b 0

:load_env_value
setlocal
set "FILE_PATH=%~1"
set "KEY_NAME=%~2"
set "VALUE="
if not exist "%FILE_PATH%" (
  endlocal & exit /b 0
)
for /f "usebackq tokens=1,* delims==" %%A in (`findstr /B /I "%KEY_NAME%=" "%FILE_PATH%"`) do (
  set "VALUE=%%B"
)
if not defined VALUE (
  endlocal & exit /b 0
)
if /I "%VALUE%"=="true" set "VALUE=1"
if /I "%VALUE%"=="false" set "VALUE=0"
endlocal & set "%~3=%VALUE%"
exit /b 0

:auto_push_configs
echo.
echo [PHASE git] Публикация configs\ в GitHub...

where git >nul 2>&1
if errorlevel 1 (
  echo [WARNING] Git не найден. Авто-публикация configs\ пропущена.
  exit /b 0
)

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 (
  echo [WARNING] Текущая папка не git-репозиторий. Авто-публикация пропущена.
  exit /b 0
)

git remote get-url origin >nul 2>&1
if errorlevel 1 (
  echo [WARNING] remote origin не настроен. Авто-публикация пропущена.
  exit /b 0
)

git add configs
git diff --cached --quiet -- configs
if not errorlevel 1 (
  echo [INFO] Изменений в configs\ нет. Публикация не требуется.
  exit /b 0
)

for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH-mm-ss"') do set "NOW_TS=%%I"
set "COMMIT_MSG=%CONFIGS_COMMIT_PREFIX% [%NOW_TS%]"

git commit -m "%COMMIT_MSG%" -- configs
if errorlevel 1 (
  echo [WARNING] Не удалось создать commit для configs\. Проверьте git user.name/user.email.
  exit /b 0
)

git push origin HEAD:%CONFIGS_PUSH_BRANCH%
if errorlevel 1 (
  echo [WARNING] Не удалось выполнить git push. Проверьте права доступа к GitHub и токен/SSH.
  exit /b 0
)

echo [SUCCESS] configs\ успешно отправлены в GitHub ^(branch: %CONFIGS_PUSH_BRANCH%^).
exit /b 0

:help
echo Usage:
echo   run_github_like.bat [--skip-daily] [--skip-docker] [--mtproto] [--no-speedtest] [--git-push] [--no-git-push]
echo.
echo Flags:
echo   --skip-daily   пропустить python daily check
echo   --skip-docker  пропустить docker этап
echo   --mtproto      добавить опциональный mtproto этап (из configs\mtproto)
echo   --no-speedtest не включать SPEED_TEST_ENABLED=true на Docker-этапе
echo   --git-push     включить авто-push папки configs\ в GitHub после запуска
echo   --no-git-push  отключить авто-push папки configs\ в GitHub после запуска
exit /b 0
