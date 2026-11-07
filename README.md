# llama.cpp для Windows — Установка, Обновление и Удаление

Комплект скриптов для развёртывания и обслуживания [llama.cpp](https://github.com/ggml-org/llama.cpp) на Windows в виде службы через [NSSM](https://nssm.cc). Сервер запускается как `llama-server.exe` с параметрами из INI. Оптимизирован под **NVIDIA RTX 4060 (8 ГБ VRAM)**, но работает на любом железе с подстройкой INI.

## Состав комплекта

| Файл | Назначение |
|---|---|
| `llama-windows-install.ini` | Единый конфиг (пути, сеть, версия, параметры llama-server) |
| `llama-windows-install.ps1` | Установка, обновление, переустановка, диагностика |
| `llama-windows-uninstall.ps1` | Удаление службы и очистка |
| `README.md` | Этот файл (документация) |

Все четыре файла должны лежать в одной папке — например, `D:\AI\Llama.cpp\Install`.

## Основные возможности

1. **Безопасная папка `Install`.** Скрипты и лог-файл хранятся в `D:\AI\Llama.cpp\Install`. При обновлении/переустановке эта папка **никогда не удаляется**.

2. **Защищённые папки внутри `LlamaCppDir`:** `Install\`, `logs\`, `Downloads\`, `Backup\`, `Models\` — не затрагиваются при обновлении.

3. **Проверка системных зависимостей:**
   - Visual C++ Redistributable 2015–2022 x64 (автоустановка при отсутствии).
   - Совместимость версии CUDA с драйвером (парсит `nvidia-smi`, поддерживает формат `CUDA UMD Version:`).
   - Объём VRAM (предупреждение при < 8 ГБ).
   - Существование файла модели `.gguf` до регистрации службы.

4. **Умное обновление/переустановка.** Меню версий с пометкой `(переустановка)` на текущей. Отмена через `s` до остановки службы.

5. **Health-check через `GET /health`.** После запуска скрипт опрашивает `http://127.0.0.1:<Port>/health` (до 120 секунд — большие модели грузятся долго).

6. **Расширенная диагностика при сбое:**
   - Останавливает службу, запускает `llama-server.exe` напрямую с `--verbose`.
   - Затем в режиме CPU (`-ngl 0`).
   - Сравнивает результаты и указывает на причину: GPU, DLL, аргументы или NSSM.

7. **ForceCPU.** Флаг `[server] ForceCPU=true` запускает сервер без GPU — для диагностики или работы на слабых машинах.

8. **NSSM в PATH.** Обе папки `win32\` и `win64\` добавляются в Machine `PATH`.

9. **Безопасные права (SID).** `*S-1-5-18` (SYSTEM) и `*S-1-5-32-544` (Administrators).

10. **Автообновление (`-Upgrade`).** Для Планировщика Windows.

11. **Ротация логов.** Файлы в `LogsDir` старше `LogRetentionDays` удаляются.

## Быстрый старт

1. Отредактируйте `llama-windows-install.ini`:
   - Проверьте `FirewallSubnet`.
   - Укажите **`Model`** — полный путь к `.gguf`.
   - Подстройте `CtxSize`, `NGpuLayers` под вашу VRAM.
2. Запустите `.\llama-windows-install.ps1`.
3. Дождитесь завершения и проверки `/health`.

## Параметры запуска `llama-windows-install.ps1`

| Параметр | Описание |
|---|---|
| `-Force` | Не задавать интерактивных вопросов. |
| `-ForceDownload` | Принудительно перекачать архивы. |
| `-Upgrade` | Автообновление: `-Force` + `LlamaCppVersion=latest`. |
| `-NoPause` | Не ждать Enter в конце. |
| `-ConfigPath` | Путь к нестандартному INI. |

## Автообновление (Планировщик Windows)

1. **Планировщик заданий** → Создать задачу.
2. Триггер: ежедневно в 3:00.
3. Действие:
   - Программа: `powershell.exe`
   - Аргументы: `-NoProfile -ExecutionPolicy Bypass -File "D:\AI\Llama.cpp\Install\llama-windows-install.ps1" -Upgrade -NoPause`
4. **«Выполнять с наивысшими правами»**.

## Удаление

```powershell
# Удалить службу, сохранив данные
.\llama-windows-uninstall.ps1

# Полная очистка
.\llama-windows-uninstall.ps1 -PurgeModels -PurgeLlamaCpp -PurgeLogs -PurgeDownloads -PurgeBackup -Force -NoPause
