#!/bin/sh
# test/run-hermetic.sh — поведенческий прогон пакета БЕЗ NAS и без живого rclone.
#
# Весь пакет запускается во временном каталоге через YD_*-оверрайды (см.
# spk/package/common.sh), движок подменяется шимом test/fake-rclone через
# переменную RCLONE. Покрывается самая хрупкая логика:
#   - машина состояний run_bisync (первый прогон/--resync, ошибка, авто-recover);
#   - окно счётчиков count_run_transfers (только последний прогон);
#   - формат sync.state: 7 полей + обратная совместимость с 3-полевым;
#   - ротация лога, single-run guard (flock), is_configured/resolve_remote;
#   - парсер cfg() из common.sh (таблица входов);
#   - контракт CLI-флагов _bisync, включая 6 exclude-масок (security-инвариант);
#   - golden-снимки человекочитаемого вывода (test/golden/).
#
# ПОРЯДОК СЦЕНАРИЕВ ЗНАЧИМ: T3 обязан идти ДО T4/T5 — те оставляют в хвосте
# rclone.log строки-триггеры recovery, и T3 после них поймал бы ложный
# авто-resync (обёртка ищет триггер в tail -n 100 лога). Новые сценарии,
# пишущие триггер в лог, добавлять только после T5.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

YD="$ROOT/spk/package/yandex-disk"
RCLONE="$ROOT/test/fake-rclone"
export RCLONE
chmod +x "$RCLONE"   # без exec-бита обёртка молча упала бы на системный rclone

export YD_PKG_DIR="$WORK/pkg" YD_HOME="$WORK/home" YD_VAR="$WORK/var"
export YD_RCLONE_CONF="$WORK/home/.config/rclone/rclone.conf"

T=""
fail() { echo "FAIL[$T]: $*" >&2; exit 1; }
ok()   { echo "ok: $T $*"; }
field() { cut -d'|' -f"$1" "$YD_VAR/sync.state"; }

# Чистый старт: настроенный пакет (непустой rclone.conf + локальная папка), пустой var.
clean_start() {
    rm -rf "$YD_VAR" "$YD_HOME" "$WORK/local"
    mkdir -p "$YD_HOME/.config/rclone" "$YD_HOME/.config/yandex-disk" "$YD_VAR" "$WORK/local"
    printf '[yandexdisk]\ntype = yandex\n' > "$YD_RCLONE_CONF"
    printf 'dir="%s"\nremote="yandexdisk:"\n' "$WORK/local" \
        > "$YD_HOME/.config/yandex-disk/config.cfg"
}

# Прочитать ключ $2 через cfg() из common.sh при YD_HOME=$1 (изолированная подоболочка).
cfg_probe() {
    YD_HOME="$1" sh -c '. "$1"; shift; cfg "$1"' probe "$ROOT/spk/package/common.sh" "$2"
}

# Вывод sync_state_line из common.sh при YD_VAR=$1.
state_line_probe() {
    YD_VAR="$1" sh -c '. "$1"; sync_state_line' probe "$ROOT/spk/package/common.sh"
}

t01_first_run_resync() {
    T=T1
    clean_start
    FAKE_SENT=2 FAKE_RECV=1 sh "$YD" sync >/dev/null || fail "exit $? (ожидался 0)"
    [ "$(field 1)" = idle ] || fail "f1=$(field 1), ожидался idle"
    [ "$(field 3)" = ok ]   || fail "f3=$(field 3), ожидался ok"
    [ "$(field 4)" = 2 ]    || fail "f4=$(field 4) (sent), ожидалось 2"
    [ "$(field 5)" = 1 ]    || fail "f5=$(field 5) (received), ожидалось 1"
    [ "$(field 6)" = 0 ]    || fail "f6=$(field 6) (modified), ожидалось 0"
    [ "$(field 7)" = 0 ]    || fail "f7=$(field 7) (deleted), ожидалось 0"
    [ -f "$YD_VAR/.bisync_resynced" ] || fail "не создан маркер baseline .bisync_resynced"
    grep -q '^===== sync started ' "$YD_VAR/logs/rclone.log" \
        || fail "нет заголовка '===== sync started' в rclone.log"
    ok "первый прогон => --resync, idle/ok, счётчики 2/1/0/0, baseline создан"
}

t02_counter_window() {
    T=T2
    FAKE_MOD=3 FAKE_DEL=1 sh "$YD" sync >/dev/null || fail "exit $? (ожидался 0)"
    [ "$(field 4)" = 0 ] || fail "f4=$(field 4) — счётчик захватил маркеры прошлого прогона"
    [ "$(field 5)" = 0 ] || fail "f5=$(field 5) — счётчик захватил маркеры прошлого прогона"
    [ "$(field 6)" = 3 ] || fail "f6=$(field 6) (modified), ожидалось 3"
    [ "$(field 7)" = 1 ] || fail "f7=$(field 7) (deleted), ожидалось 1"
    ok "окно счётчиков = только последний прогон (0/0/3/1)"
}

t03_error_no_trigger() {
    T=T3
    rc=0; FAKE_RC=7 sh "$YD" sync >/dev/null 2>&1 || rc=$?
    [ "$rc" = 7 ] || fail "rc=$rc, ожидался 7"
    [ "$(field 1)" = error ]  || fail "f1=$(field 1), ожидался error"
    [ "$(field 3)" = "rc=7" ] || fail "f3=$(field 3), ожидалось rc=7"
    ok "падение без триггера => error/rc=7, авто-recover не запускался"
}

t04_auto_recover_ok() {
    T=T4
    out=$(FAKE_RC=1 FAKE_NEED_RESYNC=1 sh "$YD" sync) \
        || fail "exit $? (ожидался 0 после успешного recovery)"
    case "$out" in *"[auto-recover]"*) ;; *) fail "в stdout нет строки [auto-recover]";; esac
    [ "$(field 1)" = idle ] || fail "f1=$(field 1), ожидался idle после recovery"
    [ "$(field 3)" = ok ]   || fail "f3=$(field 3), ожидался ok после recovery"
    ok "триггер в логе => авто --resync => idle/ok"
}

t05_auto_recover_fail() {
    T=T5
    rc=0; FAKE_RC=1 FAKE_NEED_RESYNC=1 FAKE_RESYNC_RC=1 sh "$YD" sync >/dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ] || fail "rc=$rc, ожидался 1"
    [ "$(field 1)" = error ]  || fail "f1=$(field 1), ожидался error"
    [ "$(field 3)" = "rc=1" ] || fail "f3=$(field 3), ожидалось rc=1"
    ok "recovery тоже падает => error/rc=1"
}

t13_bisync_cli_contract() {
    T=T13
    FAKE_ARGS_FILE="$WORK/args" sh "$YD" sync >/dev/null || fail "exit $? (ожидался 0)"
    # grep -qxF --: разделитель опций обязателен — маски, начинающиеся с '--',
    # иначе прочитались бы как опции самого grep.
    for want in --conflict-resolve path1 --inplace --max-lock \
                '#recycle/**' '@eaDir/**' '#snapshot/**' '@tmp/**' .DS_Store Thumbs.db; do
        grep -qxF -- "$want" "$WORK/args" \
            || fail "в вызове bisync нет аргумента '$want' (сломан контракт _bisync / урезан exclude)"
    done
    ok "контракт CLI: conflict-resolve path1, inplace, max-lock и все 6 exclude-масок"
}

t06_single_run_guard() {
    T=T6
    command -v flock >/dev/null 2>&1 || fail "flock недоступен в тестовой среде"
    flock "$YD_VAR/sync.lock" sleep 3 &
    bg=$!
    sleep 1
    out=$(sh "$YD" sync) || fail "exit $? (ожидался 0 при skip)"
    case "$out" in *"sync already running, skip"*) ;; *) fail "нет 'sync already running, skip'";; esac
    grep -q '^===== sync skipped ' "$YD_VAR/logs/rclone.log" \
        || fail "skip не записан в rclone.log"
    wait "$bg" || true
    ok "второй параллельный sync пропущен и записан в лог"
}

t07_log_rotation() {
    T=T7
    printf '%0200d\n' 0 >> "$YD_VAR/logs/rclone.log"   # гарантированно превысить лимит
    YD_LOG_MAX_BYTES=100 sh "$YD" sync >/dev/null || fail "exit $? (ожидался 0)"
    [ -f "$YD_VAR/logs/rclone.log.1" ] || fail "нет rclone.log.1 после превышения YD_LOG_MAX_BYTES"
    ok "ротация: rclone.log -> rclone.log.1 при YD_LOG_MAX_BYTES=100"
}

t08_not_configured() {
    T=T8
    h="$WORK/t8home"
    mkdir -p "$h/.config/rclone"
    : > "$h/.config/rclone/rclone.conf"   # без секций
    rc=0
    out=$(YD_HOME="$h" YD_VAR="$WORK/t8var" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" sync 2>&1) || rc=$?
    [ "$rc" = 1 ] || fail "rc=$rc, ожидался 1"
    case "$out" in *"not configured"*) ;; *) fail "нет понятной ошибки 'not configured'";; esac
    ok "пустой rclone.conf => 'not configured', rc=1"
}

t09_resolve_remote() {
    T=T9
    h="$WORK/t9home"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$WORK/t9local"
    printf '[mydisk]\ntype = yandex\n' > "$h/.config/rclone/rclone.conf"
    printf 'dir="%s"\nremote="yandexdisk:"\n' "$WORK/t9local" > "$h/.config/yandex-disk/config.cfg"
    out=$(YD_HOME="$h" YD_VAR="$WORK/t9var" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" status) || fail "status exit $?"
    case "$out" in *"mydisk:"*) ;; *) fail "status не подхватил единственный remote [mydisk]";; esac
    ok "единственный чужой remote (mydisk) подхвачен вместо yandexdisk"
}

t10_cfg_parser() {
    T=T10
    h="$WORK/t10home"
    mkdir -p "$h/.config/yandex-disk"
    printf 'dir="/volume1/d"\n' > "$h/.config/yandex-disk/config.cfg"
    val=$(cfg_probe "$h" dir)
    [ "$val" = "/volume1/d" ] || fail "кавычки: '$val', ожидалось /volume1/d"
    printf 'dir = /v/d # коммент\n' > "$h/.config/yandex-disk/config.cfg"
    val=$(cfg_probe "$h" dir)
    [ "$val" = "/v/d" ] || fail "пробелы + инлайн-комментарий: '$val', ожидалось /v/d"
    printf 'DIR="x"\n' > "$h/.config/yandex-disk/config.cfg"
    val=$(cfg_probe "$h" dir)
    [ "$val" = "x" ] || fail "регистронезависимость: '$val', ожидалось x"
    printf 'other=1\n' > "$h/.config/yandex-disk/config.cfg"
    rc=0; val=$(cfg_probe "$h" dir) || rc=$?
    [ "$rc" = 0 ]  || fail "отсутствующий ключ: rc=$rc, ожидался 0"
    [ -z "$val" ]  || fail "отсутствующий ключ: '$val', ожидалась пустая строка"
    ok "cfg(): кавычки, пробелы, инлайн-комментарий, регистр, отсутствующий ключ"
}

t11_state_line_3field() {
    T=T11
    v="$WORK/t11var"; mkdir -p "$v"
    printf 'idle|01.01.2026 - 00:00:00|ok\n' > "$v/sync.state"
    out=$(state_line_probe "$v")
    n=$(printf '%s\n' "$out" | wc -l)
    [ "$n" = 1 ] || fail "строк: $n, ожидалась 1"
    case "$out" in *"Файлы —"*) fail "3-полевой state не должен печатать счётчики";; esac
    ok "старый 3-полевой sync.state: одна строка, без счётчиков"
}

t12_state_line_7field() {
    T=T12
    v="$WORK/t12var"; mkdir -p "$v"
    printf 'idle|01.01.2026 - 00:00:00|ok|2|1|0|0\n' > "$v/sync.state"
    out=$(state_line_probe "$v")
    n=$(printf '%s\n' "$out" | wc -l)
    [ "$n" = 2 ] || fail "строк: $n, ожидались 2"
    line2=$(printf '%s\n' "$out" | sed -n 2p)
    case "$line2" in *"отправлено): 2"*) ;; *) fail "нет 'отправлено): 2' во 2-й строке: $line2";; esac
    case "$line2" in *"получено): 1"*)  ;; *) fail "нет 'получено): 1' во 2-й строке: $line2";; esac
    ok "7-полевой sync.state: 2 строки, счётчики разобраны"
}

# --- Golden-снимки наблюдаемого контракта (test/golden/) --------------------
# Фиксируют ТОЧНЫЙ человекочитаемый вывод, который видят пользователь и UI.
# Переменные части нормализуются: путь WORK -> <WORK>, таймстемп -> <TS>.

norm() {
    sed -e "s#$WORK#<WORK>#g" \
        -e 's/[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9][0-9][0-9] - [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/<TS>/g'
}

golden_cmp() {
    diff -u "$ROOT/test/golden/$1" "$2" \
        || fail "golden '$1': контракт изменился — обнови эталон осознанно, в том же коммите, с объяснением"
    ok "вывод совпал с эталоном $1"
}

g01_status_configured() {
    T=G1
    clean_start
    sh "$YD" sync >/dev/null || fail "подготовительный sync: exit $?"
    rm -f "$YD_VAR/rclone.version"   # сбросить кэш версии перед снимком (Г-2 W7)
    sh "$YD" status | norm > "$WORK/actual"
    golden_cmp status-configured.txt "$WORK/actual"
}

g02_status_unconfigured() {
    T=G2
    h="$WORK/gUhome"
    mkdir -p "$h/.config/rclone"
    : > "$h/.config/rclone/rclone.conf"
    YD_HOME="$h" YD_VAR="$WORK/gUvar" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
        sh "$YD" status | norm > "$WORK/actual"
    golden_cmp status-unconfigured.txt "$WORK/actual"
}

g03_state_line_7field() {
    T=G3
    v="$WORK/g3var"; mkdir -p "$v"
    printf 'idle|01.01.2026 - 00:00:00|ok|2|1|0|0\n' > "$v/sync.state"
    { state_line_probe "$v"; echo; } | norm > "$WORK/actual"
    golden_cmp state-line-7field.txt "$WORK/actual"
}

g04_state_line_3field() {
    T=G4
    v="$WORK/g4var"; mkdir -p "$v"
    printf 'idle|01.01.2026 - 00:00:00|ok\n' > "$v/sync.state"
    { state_line_probe "$v"; echo; } | norm > "$WORK/actual"
    golden_cmp state-line-3field.txt "$WORK/actual"
}

echo "== Герметичный прогон: fake-rclone + YD_*-оверрайды (WORK=$WORK) =="
t01_first_run_resync
t02_counter_window
t03_error_no_trigger
t04_auto_recover_ok
t05_auto_recover_fail
t13_bisync_cli_contract
t06_single_run_guard
t07_log_rotation
t08_not_configured
t09_resolve_remote
t10_cfg_parser
t11_state_line_3field
t12_state_line_7field
g01_status_configured
g02_status_unconfigured
g03_state_line_7field
g04_state_line_3field

echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
