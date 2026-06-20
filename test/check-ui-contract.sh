#!/bin/sh
# test/check-ui-contract.sh — off-NAS guard that the package ships the CORRECT,
# CURRENT DSM UI.
#
# Why this exists: build.sh statically validates every SHELL script but nothing
# validated the UI itself (main.js / config / style.css). So a stale or broken
# main.js — e.g. an old cached build, a bad merge, or a half-finished rewrite —
# would sail through every gate green and only surface on the NAS. This check
# makes "the new dashboard UI is what actually goes into the .spk" mechanical and
# deterministic (sh + python3 only; no node/jsdom, see NOTE).
#
# It asserts the STRUCTURAL contract that distinguishes the shipped UI:
#   - app registration agrees across spk/INFO <-> ui/config <-> main.js;
#   - the new dashboard markers are present and the OLD tabbed-UI markers ABSENT
#     (so an accidentally re-shipped pre-2.0 main.js fails the gate);
#   - every CGI main.js calls is actually packaged as a #!/bin/sh script;
#   - the canon "tab key = CGI name" endpoints (status/log/sync_log + settings)
#     exist; style.css carries the new classes.
#
# NOTE (DSM cache, NOT testable here): a CORRECT main.js can still look "not
# updated" after an in-place package upgrade, because the browser / DSM desktop
# caches the old /webman/3rdparty/<pkg>/main.js (the resource URL doesn't change
# with the package version). That is a client-side cache issue — fix by
# hard-refreshing the DSM desktop or re-logging-in; no off-NAS test can catch it.
# This gate proves the OTHER half: the bytes we ship are the right UI.
#
# shellcheck shell=sh
set -eu
cd "$(dirname "$0")/.."

fail() { echo "FAIL(ui-contract): $*" >&2; exit 1; }

UIDIR="spk/package/ui"
MAIN="$UIDIR/main.js"
CONF="$UIDIR/config"
CSS="$UIDIR/style.css"

[ -f "$MAIN" ] || fail "нет $MAIN"
[ -f "$CONF" ] || fail "нет $CONF"
[ -f "$CSS" ]  || fail "нет $CSS"

# The DSM app-instance class is the canon UI contract; spk/INFO is its one source.
APPNAME=$(sed -n 's/^dsmappname="\(.*\)"/\1/p' spk/INFO)
[ -n "$APPNAME" ] || fail "dsmappname отсутствует в spk/INFO"

# 1) ui/config — валидный JSON и регистрирует приложение (config <-> INFO).
python3 - "$APPNAME" "$CONF" <<'PY' || fail "ui/config не регистрирует приложение (детали выше)"
import json, sys
appname, path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception as e:                       # noqa: BLE001 — любой сбой парсинга = провал
    print("  ui/config не парсится как JSON: %s" % e); sys.exit(1)
if "main.js" not in d:
    print('  ui/config: нет ключа "main.js"'); sys.exit(1)
inner = d["main.js"]
if appname not in inner:
    print("  ui/config: приложение %s не зарегистрировано" % appname); sys.exit(1)
app = inner[appname]
if app.get("type") != "app":
    print('  ui/config: type=%r, ожидался "app"' % app.get("type")); sys.exit(1)
if app.get("appWindow") != appname:
    print("  ui/config: appWindow=%r != %s" % (app.get("appWindow"), appname)); sys.exit(1)
PY

# 2) main.js определяет тот же класс приложения, что зарегистрирован в config/INFO.
grep -Fq "$APPNAME" "$MAIN" || fail "main.js не определяет $APPNAME"

# 3) Это НОВЫЙ дашборд, а не старый вкладочный UI. Маркеры подобраны так, чтобы
#    случайно отгруженный pre-2.0 main.js провалил гейт (ровно инцидент 2.0.0).
grep -q 'yd-app'       "$MAIN" || fail "нет корня нового UI (yd-app) — похоже, отгружается старый/чужой main.js"
grep -q 'v-app-window' "$MAIN" || fail "нет SUI-окна v-app-window (контракт окна DSM)"
for old in top-buttons tab-caption; do
    if grep -q "$old" "$MAIN"; then
        fail "в main.js найден маркер СТАРОГО UI ($old) — отгружается устаревший интерфейс"
    fi
done

# 4) Контракт данных нового UI: настройка идёт через settings.cgi / get-config.
grep -q 'settings\.cgi' "$MAIN" || fail "main.js не обращается к settings.cgi (нет нового потока настройки)"
grep -q 'get-config'    "$MAIN" || fail "main.js не использует действие get-config (преднаполнение формы)"

# 5) Каждый CGI, который зовёт main.js, реально лежит в пакете и является sh-скриптом.
CGIS=$(grep -oE '[a-z_]+\.cgi' "$MAIN" | sort -u)
[ -n "$CGIS" ] || fail "main.js не ссылается ни на один CGI (подозрительно)"
for cgi in $CGIS; do
    f="$UIDIR/scripts/$cgi"
    [ -f "$f" ] || fail "main.js зовёт $cgi, но $f отсутствует в пакете"
    head -1 "$f" | grep -q '^#!/bin/sh' || fail "$f не является #!/bin/sh-скриптом"
done

# 6) Канон «ключ вкладки = имя CGI»: status/log/sync_log + новый settings обязаны быть.
for cgi in status.cgi log.cgi sync_log.cgi settings.cgi; do
    [ -f "$UIDIR/scripts/$cgi" ] || fail "канонический CGI $cgi отсутствует"
done

# 7) style.css — новый (классы дашборда), не устаревший.
grep -q 'yd-app' "$CSS" || fail "style.css без классов нового UI (yd-app) — устаревшие стили"

# 8) settings.cgi исполняется как САМ пользователь пакета (conf/privilege: run-as: package),
#    поэтому privilege-drop через sudo не нужен и ЛОМАЕТСЯ в synoscgi (sc-yandexdisk не может
#    беспарольно sudo) — это был HTTP 500 на вкладке настроек 2.0.x. В КОДЕ settings.cgi (без
#    строк-комментариев) не должно быть вызова sudo: вся работа с конфигом идёт напрямую.
if grep -vE '^[[:space:]]*#' "$UIDIR/scripts/settings.cgi" | grep -q 'sudo'; then
    fail "settings.cgi вызывает sudo — CGI пакета исполняется как sc-yandexdisk (run-as: package); privilege-drop зависает в synoscgi (HTTP 500). Все операции с конфигом должны быть прямыми"
fi

echo "  ok (ui)   $APPNAME зарегистрирован; новый дашборд (yd-app), без старых вкладок; CGI: $(echo "$CGIS" | tr '\n' ' ')"
