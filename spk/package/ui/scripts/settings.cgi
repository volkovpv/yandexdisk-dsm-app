#!/bin/sh
# settings.cgi — тонкий CGI вкладки «Настройки» (ключ settings = имя CGI, контракт канона).
#
# Назначение (план §4, spec §4): дать DSM-интерфейсу настраивать пакет БЕЗ SSH. CGI —
# только парсер HTTP: разбирает метод/действие/тело и ДЕЛЕГИРУЕТ всё в обёртку
# yandex-disk. Вся логика/валидация/запись живёт там и в common.sh (единый источник
# истины канона), CGI не дублирует ни путей, ни парсера.
#
# Действия (action= в QUERY_STRING):
#   GET  get-config              -> JSON {dir,remote,clean_thumbs,interval,token_configured}
#   POST set-folder  (тело)      -> запись config.cfg; тело = 3 строки dir\nremote\nclean_thumbs
#   POST set-token   (тело)      -> запись rclone.conf; тело = JSON-токен ВЕРБАТИМ -> stdin
#   POST check-folder(тело)      -> JSON {exists,writable,owner}; тело = путь одной строкой
#   POST sync                    -> запустить yandex-disk sync (детали — в журнале rclone)
#
# Привилегии (Phase 0 §3.1, §11.1): на NAS этот CGI исполняется как root, но конфиги
# обязаны принадлежать sc-yandexdisk (rclone.conf 0600), а check-folder обязан мерить
# право записи ИМЕННО для sc-yandexdisk (как root «-w» истинно почти всегда — ложь для
# UI). Поэтому КАЖДЫЙ вызов обёртки идёт со сбросом привилегий: sudo -u sc-yandexdisk
# (тот же путь, что у периодического sync в Планировщике задач). Герметичный тест
# выставляет YD_RUNAS= (пусто): off-NAS такого пользователя нет и процесс уже
# непривилегирован, обёртка зовётся напрямую (так YD_*-оверрайды теста доходят до неё —
# sudo с env_reset их бы вычистил).
#
# Безопасность (§6, §7): токен приходит ТОЛЬКО телом POST и стримится в stdin set-token
# (read_body | yd set-token), НИКОГДА не в argv/QUERY_STRING/переменную/лог. Мутации
# (POST) требуют DSM SynoToken (CSRF) — здесь проверяется НАЛИЧИЕ; валидность сессии
# обеспечивает webman за DSM-логином (NAS-проверка, §9). Инъекция в root-CGI =
# компрометация root, поэтому ввод не интерпретируется оболочкой: action ограничен
# [A-Za-z-], dir/remote уходят в обёртку как argv (она их валидирует §3.4),
# проценто-декодирование НЕ применяется (тело — сырые байты, UTF-8/пробелы в пути целы;
# dash printf %b не умеет \xHH, так что «стандартный» urldecode непортируем).

set -u

# --- Расположение обёртки (self-relative, как common.sh у самой обёртки) ------
# Установлено: target/ui/scripts/settings.cgi -> обёртка target/yandex-disk. YD_BIN
# переопределяется в тестах/нестандартной установке; иначе вычисляется от $0.
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd 2>/dev/null || echo /var/packages/YandexDisk/target/ui/scripts)
PKG_TARGET=$(cd "$SELF_DIR/../.." 2>/dev/null && pwd 2>/dev/null || echo /var/packages/YandexDisk/target)
YD_BIN="${YD_BIN:-$PKG_TARGET/yandex-disk}"

# Префикс сброса привилегий (см. шапку). UNSET => sudo (NAS, root); выставлено в пусто
# тестом => прямой вызов обёртки в том же процессе (YD_*-окружение сохраняется).
RUNAS="${YD_RUNAS-sudo -u sc-yandexdisk}"

# yd <subcommand> [args...] — вызвать обёртку (со сбросом привилегий на NAS). stdin
# проксируется как есть (sudo пробрасывает stdin) — это нужно set-token.
yd() {
    if [ -n "$RUNAS" ]; then
        # shellcheck disable=SC2086  # RUNAS — доверенный константный префикс, ОБЯЗАН разбиться на слова
        $RUNAS "$YD_BIN" "$@"
    else
        "$YD_BIN" "$@"
    fi
}

# --- HTTP-ответ --------------------------------------------------------------
# Заголовки в стиле существующих CGI (LF; webman принимает). Успех (200) — без
# Status-строки (как у status.cgi/log.cgi); ошибка несёт Status с кодом.
head_ok()  { echo "Content-Type: application/json; charset=utf-8"; echo ""; }
head_err() { echo "Status: $1"; echo "Content-Type: application/json; charset=utf-8"; echo ""; }

# Экранирование значения для JSON-строки. Значения из обёртки уже без '"' (cfg() их
# срезает) и без перевода строки (validate_dir это гарантирует на записи), но защищаемся
# от любых: переводы строк/CR -> пробелы (одна строка JSON), затем '\' и '"' -> экранируем.
jesc() { printf '%s' "${1:-}" | tr '\n\r' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

json_error() {  # $1=status-строка (напр. "400 Bad Request"), $2=сообщение
    head_err "$1"
    printf '{"ok":false,"error":"%s"}\n' "$(jesc "$2")"
}

json_ok_msg() {  # $1=сообщение
    head_ok
    printf '{"ok":true,"message":"%s"}\n' "$(jesc "$1")"
}

# Прочитать ровно CONTENT_LENGTH байт тела POST. По байту: pipe/сокет может вернуть
# короткое чтение, а тела крошечные (путь / 3 строки / JSON-токен). Возвращает пусто,
# если длины нет/0. Для set-token читается в pipe (секрет НЕ оседает в переменной).
read_body() {
    _len="${CONTENT_LENGTH:-0}"
    case "$_len" in ''|*[!0-9]*) _len=0 ;; esac
    [ "$_len" -gt 0 ] || return 0
    dd bs=1 count="$_len" 2>/dev/null
}

# CSRF (§6/§7): мутации обязаны нести DSM SynoToken — его шлёт аутентифицированный UI
# (заголовок X-SYNO-TOKEN => HTTP_X_SYNO_TOKEN, либо параметр SynoToken=), а кросс-сайт
# его прочитать не может. Проверяем НАЛИЧИЕ; валидность сессии — webman (NAS, §9).
require_csrf() {
    [ -n "${HTTP_X_SYNO_TOKEN:-}" ] && return 0
    case "${QUERY_STRING:-}" in *SynoToken=?*) return 0 ;; esac
    return 1
}

# --- Реализация действий -----------------------------------------------------
# Преднаполнение формы: текущий конфиг как JSON. token_configured — булев флаг (БЕЗ
# значения токена). interval пока всегда пуст (Опция B вне MVP) — поле задела под §3.3.
do_get_config() {
    _out=$(yd get-config 2>/dev/null) \
        || { json_error "500 Internal Server Error" "get-config failed"; return; }
    _dir=$(printf '%s\n' "$_out" | sed -n 's/^dir=//p')
    _remote=$(printf '%s\n' "$_out" | sed -n 's/^remote=//p')
    _ct=$(printf '%s\n' "$_out" | sed -n 's/^clean_thumbs=//p')
    _interval=$(printf '%s\n' "$_out" | sed -n 's/^interval=//p')
    _tokbool=false
    [ "$(printf '%s\n' "$_out" | sed -n 's/^token_configured=//p')" = 1 ] && _tokbool=true
    head_ok
    printf '{"dir":"%s","remote":"%s","clean_thumbs":"%s","interval":"%s","token_configured":%s}\n' \
        "$(jesc "$_dir")" "$(jesc "$_remote")" "$(jesc "$_ct")" "$(jesc "$_interval")" "$_tokbool"
}

# Живая проверка папки: существует / доступна на запись sc-yandexdisk / владелец.
# Тело = путь одной строкой (сырые байты — UTF-8/пробелы целы, без urldecode).
do_check_folder() {
    _dir=$(read_body | sed -n '1p')
    _out=$(yd check-folder "$_dir" 2>/dev/null) \
        || { json_error "400 Bad Request" "check-folder failed"; return; }
    _ex=false;  [ "$(printf '%s\n' "$_out" | sed -n 's/^exists=//p')"   = 1 ] && _ex=true
    _wr=false;  [ "$(printf '%s\n' "$_out" | sed -n 's/^writable=//p')" = 1 ] && _wr=true
    _own=$(printf '%s\n' "$_out" | sed -n 's/^owner=//p')
    head_ok
    printf '{"exists":%s,"writable":%s,"owner":"%s"}\n' "$_ex" "$_wr" "$(jesc "$_own")"
}

# Запись config.cfg. Тело = 3 строки: dir, remote, clean_thumbs (любая может быть пустой
# — обёртка подставит дефолты remote=yandexdisk:/clean_thumbs=0 и провалидирует §3.4).
do_set_folder() {
    _body=$(read_body)
    _dir=$(printf '%s\n' "$_body" | sed -n '1p')
    _remote=$(printf '%s\n' "$_body" | sed -n '2p')
    _ct=$(printf '%s\n' "$_body" | sed -n '3p')
    _out=$(yd set-folder "$_dir" "$_remote" "$_ct" 2>&1); _rc=$?
    case "$_rc" in
        0) json_ok_msg "$_out" ;;
        2) json_error "400 Bad Request" "$_out" ;;
        *) json_error "500 Internal Server Error" "$_out" ;;
    esac
}

# Запись rclone.conf. Секрет стримится прямо в stdin set-token и НЕ оседает в переменной;
# в _out — только подтверждение/ошибка обёртки (она ГАРАНТИРОВАННО не печатает токен —
# инвариант CLAUDE.md, тесты T35/T36), поэтому surface этого вывода безопасен.
do_set_token() {
    _out=$(read_body | yd set-token 2>&1); _rc=$?
    case "$_rc" in
        0) json_ok_msg "$_out" ;;
        2) json_error "400 Bad Request" "$_out" ;;
        *) json_error "500 Internal Server Error" "$_out" ;;
    esac
}

# «Синхронизировать сейчас». Делегирует тот же sync, что и Планировщик задач. Подробный
# вывод rclone обёртка пишет в rclone.log (его показывает вкладка «Журнал синхронизации»),
# поэтому в ответ возвращаем только итог — без многострочного лога в JSON.
do_sync() {
    if yd sync >/dev/null 2>&1; then
        json_ok_msg "Синхронизация выполнена"
    else
        json_error "500 Internal Server Error" "Синхронизация завершилась с ошибкой (см. журнал rclone)"
    fi
}

# --- Роутинг -----------------------------------------------------------------
method="${REQUEST_METHOD:-GET}"
action=""
case "${QUERY_STRING:-}" in
    *action=*) action=$(printf '%s' "$QUERY_STRING" | sed -n 's/.*action=\([A-Za-z-]*\).*/\1/p') ;;
esac

case "$action" in
    get-config)
        [ "$method" = GET ] || { json_error "405 Method Not Allowed" "use GET"; exit 0; }
        do_get_config
        ;;
    check-folder|set-folder|set-token|sync)
        [ "$method" = POST ] || { json_error "405 Method Not Allowed" "use POST"; exit 0; }
        require_csrf || { json_error "403 Forbidden" "missing SynoToken (CSRF)"; exit 0; }
        case "$action" in
            check-folder) do_check_folder ;;
            set-folder)   do_set_folder ;;
            set-token)    do_set_token ;;
            sync)         do_sync ;;
        esac
        ;;
    *)
        json_error "400 Bad Request" "unknown or missing action"
        ;;
esac
exit 0
