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
if /I "%~1"=="--help" goto :help
echo [WARNING] Неизвестный аргумент: %~1
shift
goto :parse_args

:args_done
echo ==================================================
echo   GitHub-like local pipeline
echo   RUN_DAILY=%RUN_DAILY%  RUN_DOCKER=%RUN_DOCKER%  RUN_MTPROTO=%RUN_MTPROTO%
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

if "%RUN_DAILY%"=="1" (
  call :detect_python
  if errorlevel 1 exit /b 1
  call :ensure_requirements
  if errorlevel 1 exit /b 1

  echo.
  echo [PHASE 1/3] Daily check (python)
  %PYTHON_CMD% -m lib.vless_checker
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

  if exist "configs\available" (
    for %%I in ("configs\available") do set "SZ=%%~zI"
  ) else (
    set "SZ=0"
  )

  if not "!SZ!"=="0" (
    echo [INFO] Передаю configs\available в Docker через stdin (как в workflow).
    type "configs\available" | docker compose run --rm -T vless-checker -
  ) else (
    echo [WARNING] configs\available пуст/отсутствует. Запуск Docker без stdin (по DEFAULT_LIST_URL/.env).
    docker compose run --rm vless-checker
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
  echo [PHASE 3/3] MTProto check (optional)
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

:help
echo Usage:
echo   run_github_like.bat [--skip-daily] [--skip-docker] [--mtproto]
echo.
echo Flags:
echo   --skip-daily   пропустить python daily check
echo   --skip-docker  пропустить docker этап
echo   --mtproto      добавить опциональный mtproto этап (из configs\mtproto)
exit /b 0
