# Настройка через терминал (SSH) — Yandex Disk (ARM) для Synology DSM

> Аудитория: пользователи и разработчики (П/Р).
> Статус: актуально (запасной/диагностический путь). Основной путь настройки —
> в корневом [`../README.md`](../README.md).

Все операции, которые выполняются в командной строке при установке, настройке и
проверке пакета. Команды на NAS запускаются **по SSH**. Источники: `README.md`,
`spk/INFO`, обёртка `spk/package/yandex-disk`, скрипты `test-on-nas-*.sh`.

> **С версии 2.0.0 первичная настройка выполняется в интерфейсе пакета в DSM —
> без SSH.** Этот документ теперь **запасной / диагностический** справочник:
> терминал нужен для диагностики, автоматизации или если интерфейс недоступен.
> Основной путь — `README.md` → «Первоначальная настройка (в интерфейсе DSM)».

> **Ключевые соглашения**
> - Системный пользователь пакета — `sc-yandexdisk` (создаётся DSM автоматически).
> - Почти все команды на NAS запускаются **от его имени**: `sudo -u sc-yandexdisk …`
>   (пароль `sudo` — от **вашей** учётки администратора DSM, не от `sc-yandexdisk`).
> - Имя remote — **ровно** `yandexdisk` (пакет ждёт именно его).
> - Пути: обёртка — `/usr/local/bin/yandex-disk`, конфиг папки —
>   `/var/packages/YandexDisk/home/.config/yandex-disk/config.cfg`,
>   конфиг rclone — `/var/packages/YandexDisk/home/.config/rclone/rclone.conf`.

---

## 1. Сценарий настройки по SSH (по порядку — запасной путь)

| № | Команда | Что делает / примечания |
|---|---------|--------------------------|
| 1 | `id sc-yandexdisk` | **На NAS.** Проверить, что системный пользователь пакета создан DSM. Должен вывести uid/gid. Если нет — пакет установлен некорректно. Перед этим в DSM дайте `sc-yandexdisk` права rw на папку синхронизации (Панель управления → Общая папка → Разрешения → «Системный внутренний пользователь»). |
| 2 | `rclone authorize "yandex"` | **На ПК с браузером** (не на NAS!). Нужен установленный rclone (rclone.org/downloads). Откроет браузер → вход в Яндекс → выдаст OAuth-токен в виде строки `{...}` между маркерами `Paste the following…` / `<---End paste`. Скопировать строку **целиком, с фигурными скобками**. |
| 3 | `sudo -u sc-yandexdisk yandex-disk setup` | **На NAS.** Мастер настройки. На вопрос `Run interactive rclone config now? [y/N]` ответить `y`. Далее по меню rclone: `n` (новый remote) → name `yandexdisk` → Storage `yandex` → `client_id`/`client_secret` пусто (Enter) → advanced `n` → авто-конфиг/браузер `n` → в `config_token>` вставить токен из шага 2 → `y` (сохранить) → `q` (выход). |
| 4 | <code>sudo -u sc-yandexdisk tee /var/packages/YandexDisk/home/.config/yandex-disk/config.cfg >/dev/null <<'EOF'<br>dir="/volume1/yandexdisk"<br>remote="yandexdisk:"<br>EOF</code> | **На NAS.** Задать локальную папку и remote. `dir` — существующая папка с правами rw у `sc-yandexdisk`; `remote` — можно подпапку, напр. `yandexdisk:/Backup`. ⚠ Комментарий `#` — только на отдельной строке, не после значения (иначе sync падает с `rc=7`). |
| 5 | `sudo -u sc-yandexdisk /usr/local/bin/yandex-disk sync` | **На NAS.** Первая синхронизация. Первый прогон делает `rclone bisync --resync` — создаёт базовую точку и **сливает** локальную папку и Диск в обе стороны. Заранее убедитесь, что в обеих именно то, что нужно объединить. При конфликте выигрывает локальная копия (`--conflict-resolve path1`). |
| 6 | `sudo -u sc-yandexdisk /usr/local/bin/yandex-disk status` | **На NAS.** Проверить состояние после первого прогона. Ожидается `idle/ok`. |

---

## 2. Расписание периодической синхронизации (Планировщик задач DSM)

Резидентного демона нет — период задаётся в GUI Планировщика задач, но **команда
внутри задачи — терминальная**:

| № | Команда (поле «Выполнить команду») | Что делает / примечания |
|---|-------------------------------------|--------------------------|
| 7 | `sudo -u sc-yandexdisk /usr/local/bin/yandex-disk sync` | Панель управления → Планировщик задач → Создать → Запланированная задача → Пользовательский сценарий. Пользователь — **root**; периодичность — напр. каждые 5 минут. Параллельные запуски исключены через `flock` (повторный прогон тихо завершается «sync already running, skip»). `HOME` обёртка выставляет сама. |

---

## 3. Альтернатива настройке remote без мастера

Если OAuth-токен (строка `{...}`) уже получен на шаге 2 — можно создать remote одной командой вместо мастера (шаг 3):

| № | Команда | Что делает / примечания |
|---|---------|--------------------------|
| 8 | `sudo -u sc-yandexdisk rclone config create yandexdisk yandex token '<JSON-ТОКЕН>' --config /var/packages/YandexDisk/home/.config/rclone/rclone.conf` | **На NAS.** Создаёт remote `yandexdisk` напрямую, без интерактивного мастера. `<JSON-ТОКЕН>` — строка `{...}` из шага 2 в одинарных кавычках. |

Альтернатива редактору для `config.cfg` (вместо `tee` на шаге 4):

| № | Команда | Что делает / примечания |
|---|---------|--------------------------|
| 9 | `sudo -u sc-yandexdisk mkdir -p /var/packages/YandexDisk/home/.config/yandex-disk` | Создать каталог конфига (если его нет). |
| 10 | `sudo -u sc-yandexdisk vi /var/packages/YandexDisk/home/.config/yandex-disk/config.cfg` | Отредактировать конфиг в `vi`. Ошибка `E212: Can't open file for writing` = нет каталога/прав (выполните шаг 9). Обязательно от имени `sc-yandexdisk` — каталог принадлежит ему. |

---

## 4. Проверка на NAS

Запускать по SSH из каталога со скриптами, рекомендуется от root (или через `sudo`):

| № | Команда | Что делает / примечания |
|---|---------|--------------------------|
| 11 | `./test-on-nas-install.sh` | Проверка установки: статус пакета (`synopkg`), архитектура rclone (aarch64), обёртка `yandex-disk`, наличие пользователя `sc-yandexdisk`, каталоги конфигурации. Печатает ✓/✗, ненулевой код выхода = есть провалы. |
| 12 | `./test-on-nas-functional.sh` | Функциональный тест: heartbeat-процесс (`yandex-logger`), `status`, логи, и безопасный тест синхронизации (создать → синхронизировать → проверить на Диске → удалить). Запускать **после** настройки remote и папки. |

---

## 5. Команды обёртки `yandex-disk` (справочник)

Полезны при диагностике; на NAS запускать от `sudo -u sc-yandexdisk`:

| № | Команда | Что делает / примечания |
|---|---------|--------------------------|
| 13 | `sudo -u sc-yandexdisk /usr/local/bin/yandex-disk version` | Версия движка rclone. |
| 14 | `sudo -u sc-yandexdisk /usr/local/bin/yandex-disk rclone <args…>` | Прямой вызов rclone с конфигом пакета. Напр. список файлов на Диске: `… rclone lsf yandexdisk:`. |
| 15 | `sudo -u sc-yandexdisk /usr/local/bin/yandex-disk start` (или `stop`) | Без эффекта — резидентного демона нет; период задаётся в Планировщике задач. Оставлены для совместимости. |

> **Настройка без SSH-мастера (те же подкоманды, что вызывает UI):**
> - токен: `printf '%s' '<JSON-ТОКЕН>' | sudo -u sc-yandexdisk /usr/local/bin/yandex-disk set-token` (JSON со stdin — не виден в `ps`);
> - папка/remote: `sudo -u sc-yandexdisk /usr/local/bin/yandex-disk set-folder /volume1/yandexdisk yandexdisk:` (3-й арг. `clean_thumbs` `0|1` — опц.);
> - текущий конфиг: `sudo -u sc-yandexdisk /usr/local/bin/yandex-disk get-config` (без значения токена); проверка папки: `… yandex-disk check-folder <dir>`.

> Подробный лог последней синхронизации: `/var/packages/YandexDisk/var/logs/rclone.log`
> (виден в UI на вкладке «Синхронизация», последние 300 строк). Туда смотреть при ошибке `rc=N`.
> Лог и история статусов автоматически ротируются по размеру (>1 МБ → `.1`).

---

## 6. Сборка пакета из исходников (для разработчика, не на NAS)

Выполняется на машине разработчика (WSL2/Linux), а не на NAS. Нужны: `bash`, `tar`,
`gzip`, `unzip`, `curl`/`wget`, `sha256sum` (опц. `dash`, `shellcheck`, `python3`).

| № | Команда | Что делает / примечания |
|---|---------|--------------------------|
| 16 | `./build.sh` | Статические проверки скриптов (`dash -n` + `shellcheck`), докачка и сверка SHA-256 rclone, сборка воспроизводимого `YandexDisk-ARM-<версия>.spk` (+ `.sha256`). |
| 17 | `sha256sum -c YandexDisk-ARM-<версия>.spk.sha256` | Проверить контрольную сумму готового `.spk`. |
| 18 | `bash build.sh && bash test/run-hermetic.sh && sh test/check-coverage.sh && bash test/check-reproducible.sh` | Полный гейт качества после нетривиальной правки (см. `CLAUDE.md` / `docs/ai-workflow.md`). |
| 19 | `sh test/mutate.sh` | Мутационный гейт (тяжёлый, ~2 мин; on-demand / ночью в CI). Порог `YD_MUT_MIN` (по умолч. 90). |
