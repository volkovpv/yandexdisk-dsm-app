# NAS-разведка: пошаговый runbook для install-self-check

Снимает разом все факты `⚠ ВЕРИФ` из §12 пропозала
[`proposal-install-self-check.md`](proposal-install-self-check.md) перед написанием
`preinst`/`postinst`. Инструмент — единый скрипт `test-on-nas-recon.sh` (в корне
репо), см. таблицу прогонов в §12-bis пропозала.

Нужны **два места**: ПК с этим репо (WSL) — там собираешь; **тестовый** NAS (DS124,
arm64) — там ставишь и наблюдаешь.

> ⚠️ Только тестовый NAS **без рабочего токена/данных**. Debug-сборка нужна для
> наблюдения за lifecycle, а не для работы. Все проверки структурные, секреты не
> читаются.

---

## A. На ПК (WSL) — собрать debug-`.spk`

```bash
cd /home/linni/www/nas/yandexdisk-dsm-app

# 1. Запечь recon в lifecycle-хуки (скрипт сам определяет фазу по имени файла):
cp test-on-nas-recon.sh spk/scripts/preinst
cp test-on-nas-recon.sh spk/scripts/postinst
chmod +x spk/scripts/preinst spk/scripts/postinst

# 2. Собрать ARM-пакет (DS124 = arm64). Выход в корне репо: YandexDisk-ARM-<ver>.spk
bash build.sh
```

Замечания:
- Хуки `preinst`/`postinst` не в `POSIX_SH` → `build.sh` их не линтует, сборка
  пройдёт. Сам recon при этом проходит `dash -n`/shellcheck/checkbashisms.
- Версию **не трогаем** (иначе drift-гейт `build.sh` уронит сборку). «Старую»
  версию для апгрейда берём отдельным файлом — шаг C.

На NAS повезём два файла из корня репо:
- `YandexDisk-ARM-<ver>.spk` — debug-сборка (хуки внутри);
- `test-on-nas-recon.sh` — для ручного режима `report`.

---

## B. Подготовить NAS

1. DSM → **Панель управления → Терминал и SNMP → Включить SSH**.
2. Зайти: `ssh твой_админ@IP_NAS` → затем `sudo -i` (в DSM 7 root по SSH закрыт,
   работаем через sudo).
3. Для апгрейд-тестов нужна «старая» версия: скачай любой **прежний релиз**
   (например 2.0.3) со страницы Releases — это будет OLD. Debug-сборка текущей
   версии встанет поверх как настоящий апгрейд, правок версии не требуется.

---

## C. Закинуть файлы на NAS

С ПК (WSL), отдельный терминал (подставь свою версию вместо `<ver>`):

```bash
cd /home/linni/www/nas/yandexdisk-dsm-app
scp YandexDisk-ARM-<ver>.spk  твой_админ@IP_NAS:/tmp/yd-debug.spk
scp test-on-nas-recon.sh      твой_админ@IP_NAS:/tmp/test-on-nas-recon.sh
# прежний релиз как OLD (для апгрейд-сценариев):
scp ~/Downloads/YandexDisk-ARM-2.0.3.spk  твой_админ@IP_NAS:/tmp/yd-old.spk
```

---

## D. Прогоны на NAS — по порядку

Всё под `sudo -i`. Перед каждым сценарием ставь метку в общий лог:

```bash
echo "##### SCENARIO: <имя> $(date) #####" >> /tmp/yd-recon.log
```

| № | Что запустить | Что СМОТРЕТЬ глазами (скрипт не увидит) |
|---|---|---|
| 1 | `sudo sh /tmp/test-on-nas-recon.sh report` (на чистом NAS) | базовый отчёт окружения |
| 2 | **Свежая, OK:** при наличии пакета `synopkg uninstall YandexDisk` → `synopkg install /tmp/yd-debug.spk` | установка прошла |
| 3 | **Свежая, postinst FAIL:** `synopkg uninstall YandexDisk` → `echo postinst > /tmp/yd-recon.fail` → **поставь через GUI** (Центр пакетов → Ручная установка → `/tmp/yd-debug.spk`) | ① текст ошибки в диалоге (сколько строк stderr); ② выжил ли каталог: `ls -ld /var/packages/YandexDisk/var`; ③ затем `rm /tmp/yd-recon.fail` |
| 4 | **Апгрейд, OK:** `synopkg uninstall YandexDisk` → `synopkg install /tmp/yd-old.spk` → `synopkg install /tmp/yd-debug.spk` | апгрейд прошёл; в логе появится `OLD=...` |
| 5 | **Апгрейд, postinst FAIL:** `synopkg uninstall YandexDisk` → `synopkg install /tmp/yd-old.spk` → `echo postinst > /tmp/yd-recon.fail` → GUI Ручная установка `/tmp/yd-debug.spk` | осталась ли СТАРАЯ версия рабочей или пакет «битый»; что в Package Center; затем `rm /tmp/yd-recon.fail` |
| 6 | **Апгрейд, preinst FAIL (главный вопрос):** `synopkg uninstall YandexDisk` → `synopkg install /tmp/yd-old.spk` → `echo preinst > /tmp/yd-recon.fail` → GUI Ручная установка `/tmp/yd-debug.spk` | **осталась ли старая версия целой и запущенной** (`synopkg status YandexDisk`); затем `rm /tmp/yd-recon.fail` |

Важно: сценарии с FAIL (3, 5, 6) ставь **через GUI «Ручная установка»**, а не
`synopkg install` — только так увидишь, что именно показывает Package Center (это и
есть пункт R5). `synopkg uninstall`/`install` удобны для быстрой подготовки
состояния.

---

## E. Куда записывать результат

Скрипт **сам копит** снимки фаз в `/tmp/yd-recon.log` (там `id`, `uname -m`,
`SYNOPKG_*`, владелец/запись `logs`, вердикт arch). DSM дублирует stdout хуков в
`/var/log/synopkg.log`. После прогонов собери всё в один файл и забери на ПК:

```bash
# на NAS:
sudo sh /tmp/test-on-nas-recon.sh report > /tmp/recon-final.txt 2>&1
# с ПК:
scp твой_админ@IP_NAS:/tmp/yd-recon.log    ./recon-snapshots.txt
scp твой_админ@IP_NAS:/tmp/recon-final.txt ./recon-final.txt
```

Дальше **перенеси факты в `proposal-install-self-check.md`, в §12** (пункты 1–6
сейчас стоят как вопросы `⚠ ВЕРИФ` — допиши под каждым ответ). Соответствие
«что → в какой пункт §12»:

| Из снимка / наблюдения | Пункт |
|---|---|
| `whoami:` (root vs sc-yandexdisk) | §12-3 (под кем бегут; нужен ли `sudo -u`) |
| `sc-user:` в preinst vs postinst | §12-3a (когда DSM создаёт `sc-yandexdisk`) |
| `host-arch` + `rclone-arch` вердикт | §10-8 / R1 (подтверждение arch-agnostic) |
| `logs-write:` + `VAR_DIR:` | §12-4 (запись в `logs`) |
| `env SYNOPKG_*` (есть ли `OLD_PKGVER`, как назван) | §12-6 / §10-10 |
| сценарий 3 (выжил ли `var`) | §12-2 → §10-4a |
| сценарии 5/6 (судьба старой версии) | §12-1, §12-2 → §10-1 |
| текст диалога Package Center | §12-5 → §5.2 |

---

## F. Уборка

На ПК:
```bash
cd /home/linni/www/nas/yandexdisk-dsm-app
rm spk/scripts/preinst spk/scripts/postinst   # убрать debug-хуки
git status                                     # убедиться, что spk/scripts чист
```
На NAS: `rm -f /tmp/yd-recon.fail /tmp/yd-recon.log /tmp/*.spk`, при желании
переустановить рабочую версию.

---

## Опционально: вторая арка x86_64

Чтобы подтвердить arch-agnostic (§10-8) и на x86_64: собрать
`YD_ARCH=amd64 bash build.sh` → `YandexDisk-x86_64-<ver>.spk` и прогнать те же шаги
на x86_64 DSM-VM. На arm64-NAS этого не требуется.

Если прежнего релиза под рукой нет — для апгрейд-сценариев вместо `/tmp/yd-old.spk`
можно поднять версию debug-сборки на патч выше (тогда синхронно править
`spk/INFO` + `CHANGELOG-ARM.md` + `RELEASE-INFO-ARM.txt`, иначе drift-гейт уронит
сборку).

---

## Связанные

- [`proposal-install-self-check.md`](proposal-install-self-check.md) — §12 / §12-bis.
- `test-on-nas-recon.sh` (корень репо) — сам разведчик (режимы A/B).
- `CLAUDE.md` — канон (POSIX-only, контракты, секреты-не-в-логи).
