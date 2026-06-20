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
#   - clean_thumbs: выкл по умолчанию, удаляет только Thumbs.db/.DS_Store (T20);
#   - второй триггер авто-recovery «Must run --resync» (T15);
#   - is_configured при пустом dir; resolve_remote при ≥2 чужих remote (T16/T17);
#   - кэш rclone.version: запись при промахе, чтение при попадании (T14);
#   - роутинг подкоманд version/rclone/start|stop/usage (T18);
#   - граница ротации лога: ровно на лимите не ротируем (T19);
#   - провал первого --resync => error/resync-failed (T21);
#   - вывод/создание config.cfg в setup; без tty не спрашивает (T22);
#   - is_configured: conf без секции при заданном dir => not configured (T23);
#   - diag: Phase-0 спайк привилегий — печатает euid (whoami/id) и пробует запись
#     в home/.config/{yandex-disk,rclone}; вердикт WRITABLE / NOT-WRITABLE (T24/T25),
#     секрет не утекает в вывод diag (T26), тонкий diag.cgi делегирует в обёртку (T27);
#   - golden-снимки человекочитаемого вывода (test/golden/).
#
# ПОРЯДОК СЦЕНАРИЕВ ЗНАЧИМ: T3 обязан идти ДО T4/T5 — те оставляют в хвосте
# rclone.log строки-триггеры recovery, и T3 после них поймал бы ложный
# авто-resync (обёртка ищет триггер в tail -n 100 лога). Новые сценарии,
# пишущие триггер в лог, добавлять только после T5. Сценарии T14+ работают в
# изолированных YD_VAR/YD_HOME (собственный rclone.log), поэтому от порядка
# относительно T1–T13 не зависят.
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

# Вызвать функцию-хелпер common.sh напрямую: common_probe <func> [args...].
# Аргументы передаются как есть (токен/путь со спецсимволами не ломается). YD_HOME/
# YD_RCLONE_CONF пробрасываются явно (sh — внешняя команда => экспорт работает), так
# что is_token_configured видит нужный rclone.conf без глобального стейта.
common_probe() {
    YD_HOME="${YD_HOME:-}" YD_RCLONE_CONF="${YD_RCLONE_CONF:-}" \
        sh -c '. "$1"; shift; "$@"' probe "$ROOT/spk/package/common.sh" "$@"
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
    for want in --conflict-resolve path1 --inplace --max-lock 15m \
                --config --log-file --log-format date,time -v \
                --create-empty-src-dirs --resilient --recover \
                --check-sync=false --transfers --checkers \
                '#recycle/**' '@eaDir/**' '#snapshot/**' '@tmp/**' .DS_Store Thumbs.db; do
        grep -qxF -- "$want" "$WORK/args" \
            || fail "в вызове bisync нет аргумента '$want' (сломан контракт _bisync / урезан exclude)"
    done
    ok "контракт CLI _bisync: все флаги (config/log/conflict/resilient/recover/inplace/max-lock/check-sync/transfers/checkers) и 6 exclude-масок"
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

# --- Дополнительное покрытие веток обёртки (T14+, изолированный YD_VAR) ------
# Каждый сценарий поднимает собственный YD_HOME/YD_VAR, поэтому не зависит от
# порядка относительно T1–T13 и не делит с ними rclone.log.

t14_version_cache() {
    T=T14
    h="$WORK/t14home"; v="$WORK/t14var"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$WORK/t14local"
    printf '[yandexdisk]\ntype = yandex\n' > "$h/.config/rclone/rclone.conf"
    printf 'dir="%s"\nremote="yandexdisk:"\n' "$WORK/t14local" > "$h/.config/yandex-disk/config.cfg"
    # Промах: породить движок и записать кэш версии.
    YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
        sh "$YD" status >/dev/null || fail "status (промах кэша) exit $?"
    [ -f "$v/rclone.version" ] || fail "кэш rclone.version не записан при промахе"
    grep -q 'rclone v1.74.3-fake' "$v/rclone.version" \
        || fail "в кэше rclone.version не строка версии движка"
    # Попадание: прочитать кэш дословно, не порождая движок заново.
    printf 'CACHED-SENTINEL\n' > "$v/rclone.version"
    out=$(YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" status) || fail "status (попадание кэша) exit $?"
    case "$out" in *CACHED-SENTINEL*) ;; *) fail "status не прочитал кэш rclone.version (повторный spawn?)";; esac
    ok "rclone.version: запись при промахе, чтение из кэша при попадании"
}

t15_auto_recover_alt_trigger() {
    T=T15
    h="$WORK/t15home"; v="$WORK/t15var"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$WORK/t15local"
    printf '[yandexdisk]\ntype = yandex\n' > "$h/.config/rclone/rclone.conf"
    printf 'dir="%s"\nremote="yandexdisk:"\n' "$WORK/t15local" > "$h/.config/yandex-disk/config.cfg"
    YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
        sh "$YD" sync >/dev/null || fail "подготовительный sync exit $?"
    # Инкрементальный прогон падает со ВТОРОЙ фразой-триггером => авто --resync.
    out=$(YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          FAKE_RC=1 FAKE_NEED_RESYNC=1 FAKE_RESYNC_MSG='Must run --resync' \
          sh "$YD" sync) || fail "exit $? (ожидался 0 после recovery по второму триггеру)"
    case "$out" in *"[auto-recover]"*) ;; *) fail "нет [auto-recover] на триггер 'Must run --resync'";; esac
    [ "$(cut -d'|' -f1 "$v/sync.state")" = idle ] || fail "статус != idle после recovery"
    [ "$(cut -d'|' -f3 "$v/sync.state")" = ok ]   || fail "результат != ok после recovery"
    ok "второй триггер recovery 'Must run --resync' => авто --resync => idle/ok"
}

t16_configured_needs_dir() {
    T=T16
    h="$WORK/t16home"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk"
    printf '[yandexdisk]\ntype = yandex\n' > "$h/.config/rclone/rclone.conf"     # секция есть
    printf 'dir=""\nremote="yandexdisk:"\n' > "$h/.config/yandex-disk/config.cfg" # но dir пуст
    rc=0
    out=$(YD_HOME="$h" YD_VAR="$WORK/t16var" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" sync 2>&1) || rc=$?
    [ "$rc" = 1 ] || fail "rc=$rc, ожидался 1 (секция есть, но dir пуст)"
    case "$out" in *"not configured"*) ;; *) fail "нет 'not configured' при пустом dir";; esac
    ok "rclone.conf с секцией, но пустой dir => 'not configured', rc=1"
}

t17_resolve_remote_ambiguous() {
    T=T17
    h="$WORK/t17home"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$WORK/t17local"
    printf '[one]\ntype = yandex\n[two]\ntype = s3\n' > "$h/.config/rclone/rclone.conf"
    printf 'dir="%s"\nremote="yandexdisk:"\n' "$WORK/t17local" > "$h/.config/yandex-disk/config.cfg"
    out=$(YD_HOME="$h" YD_VAR="$WORK/t17var" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" status) || fail "status exit $?"
    case "$out" in
        *"'yandexdisk:'"*) ;;   # REMOTE оставлен как есть — при неоднозначности не угадываем
        *) fail "при 2 чужих remote REMOTE подменён (не должен угадывать): $out";;
    esac
    ok "≥2 чужих remote, ни один не совпал => REMOTE не подменяется"
}

t18_subcommand_routing() {
    T=T18
    out=$(sh "$YD" version) || fail "version exit $?"
    case "$out" in *"rclone v1.74.3-fake"*) ;; *) fail "version не делегировал движку: $out";; esac
    out=$(sh "$YD" rclone version) || fail "rclone passthrough exit $?"
    case "$out" in *"rclone v1.74.3-fake"*) ;; *) fail "rclone <args> не проброшен движку: $out";; esac
    out=$(sh "$YD" start) || fail "start exit $?"
    case "$out" in *"No resident daemon"*) ;; *) fail "start: нет 'No resident daemon'";; esac
    out=$(sh "$YD" stop) || fail "stop exit $?"
    case "$out" in *"No resident daemon"*) ;; *) fail "stop: нет 'No resident daemon'";; esac
    rc=0; out=$(sh "$YD" frobnicate 2>&1) || rc=$?
    [ "$rc" = 1 ] || fail "неизвестная подкоманда: rc=$rc, ожидался 1"
    case "$out" in *"Usage: yandex-disk"*) ;; *) fail "нет 'Usage:' для неизвестной подкоманды";; esac
    case "$out" in *"set-folder"*) ;; *) fail "usage не упоминает UI-подкоманды (set-folder) — план §5";; esac
    ok "роутинг: version/rclone -> движок, start|stop -> no-daemon, неизвестная -> usage rc=1 (с UI-подкомандами)"
}

t19_rotate_boundary() {
    T=T19
    h="$WORK/t19home"; v="$WORK/t19var"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$v/logs" "$WORK/t19local"
    printf '[yandexdisk]\ntype = yandex\n' > "$h/.config/rclone/rclone.conf"
    printf 'dir="%s"\nremote="yandexdisk:"\n' "$WORK/t19local" > "$h/.config/yandex-disk/config.cfg"
    printf '%050d' 0 > "$v/logs/rclone.log"   # ровно 50 байт (без перевода строки)
    YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" YD_LOG_MAX_BYTES=50 \
        sh "$YD" sync >/dev/null || fail "sync exit $?"
    [ ! -f "$v/logs/rclone.log.1" ] \
        || fail "ротация сработала на границе (=лимит), а должна лишь при превышении (-gt)"
    ok "rotate_log: размер ровно на лимите => НЕ ротируем"
}

t20_clean_thumbs() {
    T=T20
    h="$WORK/t20home"; v="$WORK/t20var"; loc="$WORK/t20local"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$loc/@eaDir" "$v"
    printf '[yandexdisk]\ntype = yandex\n' > "$h/.config/rclone/rclone.conf"
    # По умолчанию clean_thumbs ВЫКЛ -> мусор обязан уцелеть.
    printf 'dir="%s"\nremote="yandexdisk:"\n' "$loc" > "$h/.config/yandex-disk/config.cfg"
    : > "$loc/Thumbs.db"; : > "$loc/.DS_Store"; : > "$loc/keep.dat"; : > "$loc/@eaDir/keep"
    YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
        sh "$YD" sync >/dev/null || fail "sync (clean_thumbs выкл) exit $?"
    [ -f "$loc/Thumbs.db" ] || fail "по умолчанию Thumbs.db не должен удаляться"
    [ -f "$loc/.DS_Store" ] || fail "по умолчанию .DS_Store не должен удаляться"
    # clean_thumbs=1 -> удалить ТОЛЬКО Thumbs.db/.DS_Store, @eaDir и прочее не трогать.
    printf 'dir="%s"\nremote="yandexdisk:"\nclean_thumbs=1\n' "$loc" > "$h/.config/yandex-disk/config.cfg"
    YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
        sh "$YD" sync >/dev/null || fail "sync (clean_thumbs=1) exit $?"
    [ ! -f "$loc/Thumbs.db" ] || fail "clean_thumbs=1: Thumbs.db не удалён"
    [ ! -f "$loc/.DS_Store" ] || fail "clean_thumbs=1: .DS_Store не удалён"
    [ -f "$loc/keep.dat" ]    || fail "clean_thumbs удалил посторонний файл keep.dat"
    [ -f "$loc/@eaDir/keep" ] || fail "clean_thumbs тронул @eaDir (нельзя — индексатор Synology)"
    ok "clean_thumbs: выкл по умолчанию; вкл => удалены только Thumbs.db/.DS_Store, @eaDir и прочее целы"
}

t21_first_run_resync_fail() {
    T=T21
    h="$WORK/t21home"; v="$WORK/t21var"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$WORK/t21local"
    printf '[yandexdisk]\ntype = yandex\n' > "$h/.config/rclone/rclone.conf"
    printf 'dir="%s"\nremote="yandexdisk:"\n' "$WORK/t21local" > "$h/.config/yandex-disk/config.cfg"
    # Первый прогон => --resync; делаем его проваленным (нет baseline -> ветка else).
    rc=0
    YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
        FAKE_RESYNC_RC=1 sh "$YD" sync >/dev/null 2>&1 || rc=$?
    [ "$rc" = 1 ] || fail "rc=$rc, ожидался 1 (провал первого --resync)"
    [ "$(cut -d'|' -f1 "$v/sync.state")" = error ]         || fail "статус != error"
    [ "$(cut -d'|' -f3 "$v/sync.state")" = resync-failed ] || fail "результат != resync-failed"
    [ ! -f "$v/.bisync_resynced" ] || fail "baseline-маркер создан при провале --resync"
    ok "первый --resync провалился => error/resync-failed, baseline не создан"
}

t22_setup_output() {
    T=T22
    h="$WORK/t22home"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk"
    # </dev/null: stdin не tty => интерактивная ветка setup пропускается.
    out=$(YD_HOME="$h" YD_VAR="$WORK/t22var" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" setup </dev/null) || fail "setup exit $?"
    case "$out" in *"rclone authorize"*) ;; *) fail "в setup нет шага авторизации rclone";; esac
    case "$out" in *"Task Scheduler"*)   ;; *) fail "в setup нет шага про Task Scheduler";; esac
    # Без tty интерактивный вопрос задавать нельзя (иначе под Планировщиком зависнет).
    case "$out" in *"Run interactive"*) fail "setup печатает интерактивный вопрос без tty";; *) ;; esac
    [ -f "$h/.config/yandex-disk/config.cfg" ] || fail "setup не создал config.cfg по умолчанию"
    ok "setup: инструкция (authorize/Task Scheduler), config.cfg по умолчанию, без tty не спрашивает интерактивно"
}

t23_configured_needs_section() {
    T=T23
    h="$WORK/t23home"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$WORK/t23local"
    : > "$h/.config/rclone/rclone.conf"   # файл есть, но БЕЗ секции [..]
    printf 'dir="%s"\nremote="yandexdisk:"\n' "$WORK/t23local" > "$h/.config/yandex-disk/config.cfg"
    rc=0
    out=$(YD_HOME="$h" YD_VAR="$WORK/t23var" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" sync 2>&1) || rc=$?
    [ "$rc" = 1 ] || fail "rc=$rc, ожидался 1 (conf без секции, хотя dir задан)"
    case "$out" in *"not configured"*) ;; *) fail "нет 'not configured' при conf без секции";; esac
    ok "rclone.conf без секции, но dir задан => 'not configured', rc=1"
}

# --- Phase 0: спайк привилегий CGI (yandex-disk diag) -----------------------
# diag печатает euid процесса (= euid CGI при вызове из webman) и проверяет,
# может ли этот euid писать конфиги пакета. Вердикт WRITABLE => ветка A (обёртка
# пишет напрямую), NOT-WRITABLE => ветка B (нужен привилегированный посредник).
# Сценарии изолированы (свой YD_HOME/YD_VAR), от порядка не зависят.

t24_diag_writable() {
    T=T24
    h="$WORK/t24home"; v="$WORK/t24var"
    # Каталоги конфигов существуют и доступны на запись => обе пробы успешны.
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk"
    out=$(YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" diag) || fail "diag exit $? (ожидался 0)"
    case "$out" in *"whoami:"*) ;; *) fail "diag не вывел whoami (euid процесса)";; esac
    case "$out" in *"euid:"*)   ;; *) fail "diag не вывел euid";; esac
    case "$out" in *"Вердикт: WRITABLE"*) ;; *) fail "обе папки доступны на запись, ожидался WRITABLE: $out";; esac
    case "$out" in *"NOT-WRITABLE"*) fail "ложный NOT-WRITABLE при доступных папках";; *) ;; esac
    # Проба не должна оставлять после себя файлов в каталогах конфигов.
    rem=$(find "$h/.config" -name '.yd-probe.*' 2>/dev/null)
    [ -z "$rem" ] || fail "diag оставил пробный файл(ы): $rem"
    ok "diag: обе папки доступны => WRITABLE (ветка A), euid выведен, пробные файлы убраны"
}

t25_diag_not_writable() {
    T=T25
    h="$WORK/t25home"
    # .config — обычный ФАЙЛ: ни один целевой каталог не создаётся (ENOTDIR даже
    # для root) => обе пробы неуспешны, root-устойчиво (не полагается на chmod).
    mkdir -p "$h"
    : > "$h/.config"
    # Захватываем stderr ОТДЕЛЬНО: неудачная проба не должна сыпать сырой ошибкой
    # оболочки ("cannot create … Directory nonexistent") — diag.cgi зовёт нас с
    # 2>&1, иначе шум попал бы в браузер.
    err="$WORK/t25.err"
    out=$(YD_HOME="$h" YD_VAR="$WORK/t25var" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" diag 2>"$err") || fail "diag exit $? (ожидался 0 даже при отказе записи)"
    case "$out" in *"Вердикт: NOT-WRITABLE"*) ;; *) fail "запись недоступна, ожидался NOT-WRITABLE: $out";; esac
    case "$out" in *"запись: НЕТ"*) ;; *) fail "нет строки 'запись: НЕТ' при отказе";; esac
    case "$out" in *"WRITABLE — применима ветка A"*) fail "ложный WRITABLE при отказе записи";; *) ;; esac
    [ ! -s "$err" ] || fail "diag сыпет в stderr при отказе записи: $(cat "$err")"
    ok "diag: запись в home/.config невозможна => NOT-WRITABLE (ветка B), stderr чист"
}

t26_diag_no_secret_leak() {
    T=T26
    h="$WORK/t26home"; v="$WORK/t26var"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk"
    # rclone.conf с СЕКРЕТОМ-сентинелом: diag НИКОГДА не должен его прочитать/вывести
    # (инвариант безопасности CLAUDE.md — токен не в stdout/лог/ответ).
    secret="ya29.SENTINEL-SECRET-TOKEN-DO-NOT-LEAK"
    printf '[yandexdisk]\ntype = yandex\ntoken = {"access_token":"%s"}\n' "$secret" \
        > "$h/.config/rclone/rclone.conf"
    out=$(YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" diag) || fail "diag exit $?"
    case "$out" in *"$secret"*) fail "СЕКРЕТ утёк в вывод diag — нарушение инварианта безопасности";; *) ;; esac
    ok "diag: секрет из rclone.conf отсутствует в выводе (не читается)"
}

t27_diag_cgi_delegates() {
    T=T27
    bindir="$WORK/t27bin"; h="$WORK/t27home"; v="$WORK/t27var"
    mkdir -p "$bindir" "$h/.config/rclone" "$h/.config/yandex-disk"
    # PATH-шим `yandex-disk`: запускает настоящую обёртку с тестовым YD_*-окружением,
    # так diag.cgi (зовёт bare `yandex-disk diag`) проверяется как на NAS.
    {
        printf '#!/bin/sh\n'
        printf 'export YD_HOME="%s" YD_VAR="%s" YD_RCLONE_CONF="%s" RCLONE="%s"\n' \
            "$h" "$v" "$h/.config/rclone/rclone.conf" "$RCLONE"
        printf 'exec sh "%s" "$@"\n' "$YD"
    } > "$bindir/yandex-disk"
    chmod +x "$bindir/yandex-disk"
    out=$(PATH="$bindir:$PATH" sh "$ROOT/spk/package/ui/scripts/diag.cgi") \
        || fail "diag.cgi exit $?"
    printf '%s\n' "$out" | head -1 | grep -qi '^Content-Type: text/plain' \
        || fail "diag.cgi не отдал заголовок Content-Type: text/plain"
    case "$out" in *"Вердикт:"*) ;; *) fail "diag.cgi не делегировал в 'yandex-disk diag' (нет вердикта)";; esac
    ok "diag.cgi: тонкий CGI отдаёт text/plain и делегирует в обёртку yandex-disk diag"
}

# --- Phase 1: настройка пакета из UI (set-folder/set-token/get-config/check-folder) ---
# Ядро без UI: валидация §3.4, атомарная запись config.cfg/rclone.conf (ветка A,
# прямой INI, §11.4), преднаполнение формы, проверка папки. Хелперы проверяются и
# напрямую (common_probe), и через подкоманды обёртки. Инвариант безопасности: токен
# НИКОГДА не в stdout. Все сценарии изолированы (свой YD_HOME/YD_VAR) и root-устойчивы.

t28_validate_dir() {
    T=T28
    rc=0; common_probe validate_dir "/volume1/Фото и видео" || rc=$?
    [ "$rc" = 0 ] || fail "validate_dir отверг валидный абсолютный путь с пробелом (rc=$rc)"
    rc=0; common_probe validate_dir "relative/path" || rc=$?
    [ "$rc" = 1 ] || fail "validate_dir принял относительный путь (rc=$rc)"
    rc=0; common_probe validate_dir "$(printf '/a\nb')" || rc=$?
    [ "$rc" = 1 ] || fail "validate_dir принял путь с переводом строки (rc=$rc)"
    rc=0; common_probe validate_dir '/a"b' || rc=$?
    [ "$rc" = 1 ] || fail "validate_dir принял путь с кавычкой — cfg() её срежет (rc=$rc)"
    rc=0; common_probe validate_dir '/a #b' || rc=$?
    [ "$rc" = 1 ] || fail "validate_dir принял путь с ' #' — cfg() срежет инлайн-комментарий (rc=$rc)"
    ok "validate_dir: абсолютный с пробелом ок; относительный/перевод строки/кавычка/' #' отвергнуты"
}

t29_validate_remote() {
    T=T29
    for good in "yandexdisk:" "yandexdisk:/Photos" "my_disk-2:" "yandexdisk:/a/b c"; do
        rc=0; common_probe validate_remote "$good" || rc=$?
        [ "$rc" = 0 ] || fail "validate_remote отверг валидный '$good' (rc=$rc)"
    done
    for bad in "yandexdisk" "yandexdisk:Photos" ":onlycolon" "bad name:"; do
        rc=0; common_probe validate_remote "$bad" || rc=$?
        [ "$rc" = 1 ] || fail "validate_remote принял невалидный '$bad' (rc=$rc)"
    done
    ok "validate_remote: NAME:/NAME:/subpath ок; без ':' / NAME:path-без-слэша / пробел в имени отвергнуты"
}

t30_validate_token() {
    T=T30
    secret="ya29.SENTINEL-DO-NOT-LEAK"
    rc=0; common_probe validate_token "{\"access_token\":\"$secret\",\"token_type\":\"OAuth\"}" || rc=$?
    [ "$rc" = 0 ] || fail "validate_token отверг валидный JSON-токен (rc=$rc)"
    rc=0; common_probe validate_token "not-json" || rc=$?
    [ "$rc" = 1 ] || fail "validate_token принял не-JSON (rc=$rc)"
    rc=0; common_probe validate_token '{"token_type":"OAuth"}' || rc=$?
    [ "$rc" = 1 ] || fail "validate_token принял JSON без access_token (rc=$rc)"
    rc=0; common_probe validate_token '{"access_token":""}' || rc=$?
    [ "$rc" = 1 ] || fail "validate_token принял пустой access_token (rc=$rc)"
    ok "validate_token: валидный JSON ок; не-JSON / без access_token / пустой токен отвергнуты"
}

t31_is_token_configured() {
    T=T31
    h="$WORK/t31home"; mkdir -p "$h/.config/rclone"
    conf="$h/.config/rclone/rclone.conf"
    rc=0; YD_RCLONE_CONF="$conf" common_probe is_token_configured || rc=$?
    [ "$rc" = 1 ] || fail "is_token_configured=true при ОТСУТСТВУЮЩЕМ rclone.conf (rc=$rc)"
    : > "$conf"   # файл есть, но без секции [yandexdisk]
    rc=0; YD_RCLONE_CONF="$conf" common_probe is_token_configured || rc=$?
    [ "$rc" = 1 ] || fail "is_token_configured=true при conf без секции [yandexdisk] (rc=$rc)"
    printf '[yandexdisk]\ntype = yandex\n' > "$conf"
    rc=0; YD_RCLONE_CONF="$conf" common_probe is_token_configured || rc=$?
    [ "$rc" = 0 ] || fail "is_token_configured=false при наличии секции [yandexdisk] (rc=$rc)"
    ok "is_token_configured: нет файла/нет секции => false; есть [yandexdisk] => true"
}

t32_set_folder_writes() {
    T=T32
    h="$WORK/t32home"; v="$WORK/t32var"; loc="$WORK/t32local"
    mkdir -p "$h/.config/yandex-disk" "$loc"
    cfgf="$h/.config/yandex-disk/config.cfg"
    out=$(YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" set-folder "$loc" "yandexdisk:/Backup" 1) \
        || fail "set-folder exit $? (ожидался 0)"
    case "$out" in *"OK:"*) ;; *) fail "set-folder не подтвердил запись: $out";; esac
    [ -f "$cfgf" ] || fail "set-folder не создал config.cfg"
    # Значения читаются обратно через cfg() из common.sh — round-trip контракта config.cfg.
    [ "$(cfg_probe "$h" dir)" = "$loc" ]              || fail "dir в config.cfg неверен: $(cfg_probe "$h" dir)"
    [ "$(cfg_probe "$h" remote)" = "yandexdisk:/Backup" ] || fail "remote неверен: $(cfg_probe "$h" remote)"
    [ "$(cfg_probe "$h" clean_thumbs)" = 1 ]          || fail "clean_thumbs неверен: $(cfg_probe "$h" clean_thumbs)"
    # Режим 0644 и отсутствие временного файла рядом (атомарность записи).
    perm=$(ls -l "$cfgf" | awk 'NR==1{print $1}')
    case "$perm" in -rw-r--r--*) ;; *) fail "config.cfg режим не 0644: $perm";; esac
    rem=$(find "$h/.config/yandex-disk" -name '.yd-write.*' 2>/dev/null)
    [ -z "$rem" ] || fail "set-folder оставил временный файл: $rem"
    ok "set-folder: config.cfg записан (dir/remote/clean_thumbs round-trip), режим 0644, temp убран"
}

t33_set_folder_rejects() {
    T=T33
    h="$WORK/t33home"; v="$WORK/t33var"; x="$WORK/t33home/x"
    mkdir -p "$h/.config/yandex-disk"
    rc=0; YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$x" sh "$YD" set-folder "rel/dir" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || fail "относительный dir: rc=$rc, ожидался 2"
    rc=0; YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$x" sh "$YD" set-folder "/ok" "bad name" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || fail "невалидный remote: rc=$rc, ожидался 2"
    rc=0; YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$x" sh "$YD" set-folder "/ok" "yandexdisk:" 7 >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || fail "невалидный clean_thumbs=7: rc=$rc, ожидался 2"
    [ ! -f "$h/.config/yandex-disk/config.cfg" ] || fail "config.cfg записан при отказе валидации"
    ok "set-folder отвергает относительный dir / плохой remote / clean_thumbs!=0|1 (rc=2), config.cfg не тронут"
}

t34_set_folder_write_fail() {
    T=T34
    h="$WORK/t34home"; mkdir -p "$h"
    # .config — ФАЙЛ => mkdir .config/yandex-disk невозможен (ENOTDIR даже для root),
    # write_cfg_atomic вернёт 1 => set-folder exit 1. Не полагается на права (root-устойчиво).
    : > "$h/.config"
    rc=0
    out=$(YD_HOME="$h" YD_VAR="$WORK/t34var" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
          sh "$YD" set-folder "/ok" "yandexdisk:" 0 2>&1) || rc=$?
    [ "$rc" = 1 ] || fail "ENOTDIR при записи config.cfg: rc=$rc, ожидался 1"
    case "$out" in *"could not write"*) ;; *) fail "нет понятного сообщения об ошибке записи: $out";; esac
    ok "set-folder: запись config.cfg невозможна (ENOTDIR) => exit 1, понятная ошибка"
}

t35_set_token_writes() {
    T=T35
    h="$WORK/t35home"; v="$WORK/t35var"
    mkdir -p "$h/.config/rclone"
    conf="$h/.config/rclone/rclone.conf"
    secret="ya29.SENTINEL-SECRET-DO-NOT-LEAK"
    out=$(printf '{"access_token":"%s","token_type":"OAuth"}' "$secret" \
          | YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$conf" sh "$YD" set-token) \
        || fail "set-token exit $? (ожидался 0)"
    case "$out" in *"$secret"*) fail "СЕКРЕТ утёк в stdout set-token — нарушение инварианта";; *) ;; esac
    [ -f "$conf" ] || fail "set-token не создал rclone.conf"
    grep -q '^\[yandexdisk\]' "$conf" || fail "в rclone.conf нет секции [yandexdisk]"
    grep -q "$secret" "$conf"          || fail "токен не записан в rclone.conf"
    perm=$(ls -l "$conf" | awk 'NR==1{print $1}')
    case "$perm" in -rw-------*) ;; *) fail "rclone.conf режим не 0600: $perm";; esac
    rem=$(find "$h/.config/rclone" -name '.yd-write.*' 2>/dev/null)
    [ -z "$rem" ] || fail "set-token оставил временный файл: $rem"
    ok "set-token: rclone.conf [yandexdisk]+токен, режим 0600, секрет НЕ в stdout, temp убран"
}

t36_set_token_rejects() {
    T=T36
    h="$WORK/t36home"; v="$WORK/t36var"
    mkdir -p "$h/.config/rclone"
    conf="$h/.config/rclone/rclone.conf"
    rc=0
    out=$(printf 'this is not a token' \
          | YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$conf" sh "$YD" set-token 2>&1) || rc=$?
    [ "$rc" = 2 ] || fail "не-JSON токен: rc=$rc, ожидался 2"
    [ ! -f "$conf" ] || fail "rclone.conf записан при отказе валидации токена"
    # Запись rclone.conf невозможна (ENOTDIR) при ВАЛИДНОМ токене => exit 1 (без утечки секрета).
    h2="$WORK/t36home2"; mkdir -p "$h2"; : > "$h2/.config"
    rc=0
    out=$(printf '{"access_token":"ya29.X"}' \
          | YD_HOME="$h2" YD_VAR="$WORK/t36var2" YD_RCLONE_CONF="$h2/.config/rclone/rclone.conf" \
            sh "$YD" set-token 2>&1) || rc=$?
    [ "$rc" = 1 ] || fail "ENOTDIR при записи rclone.conf: rc=$rc, ожидался 1"
    case "$out" in *"could not write"*) ;; *) fail "нет сообщения об ошибке записи rclone.conf: $out";; esac
    case "$out" in *"ya29.X"*) fail "СЕКРЕТ утёк в сообщение об ошибке set-token";; *) ;; esac
    ok "set-token отвергает не-JSON (rc=2, conf не тронут); ENOTDIR => exit 1 без утечки секрета"
}

t37_get_config() {
    T=T37
    # (a) Полностью настроенный пакет: dir/remote/clean_thumbs + токен в rclone.conf.
    h="$WORK/t37home"; v="$WORK/t37var"; loc="$WORK/t37local"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$loc"
    conf="$h/.config/rclone/rclone.conf"
    secret="ya29.SENTINEL-DO-NOT-LEAK-GETCONFIG"
    printf '[yandexdisk]\ntype = yandex\ntoken = {"access_token":"%s"}\n' "$secret" > "$conf"
    printf 'dir="%s"\nremote="yandexdisk:/Sub"\nclean_thumbs=1\n' "$loc" > "$h/.config/yandex-disk/config.cfg"
    out=$(YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$conf" sh "$YD" get-config) || fail "get-config exit $?"
    case "$out" in *"$secret"*) fail "СЕКРЕТ утёк в вывод get-config — нарушение инварианта";; *) ;; esac
    printf '%s\n' "$out" | grep -qx "dir=$loc"               || fail "get-config: нет 'dir=$loc': $out"
    printf '%s\n' "$out" | grep -qx "remote=yandexdisk:/Sub" || fail "get-config: неверный remote: $out"
    printf '%s\n' "$out" | grep -qx "clean_thumbs=1"         || fail "get-config: неверный clean_thumbs: $out"
    printf '%s\n' "$out" | grep -qx "token_configured=1"     || fail "get-config: token_configured!=1 при секции: $out"
    # (b) Обратная совместимость: старый config.cfg ТОЛЬКО с dir, без rclone.conf =>
    # remote подставлен по умолчанию, токен не настроен, ошибок нет.
    h2="$WORK/t37home2"; mkdir -p "$h2/.config/yandex-disk"
    printf 'dir="/legacy"\n' > "$h2/.config/yandex-disk/config.cfg"
    out=$(YD_HOME="$h2" YD_VAR="$WORK/t37var2" YD_RCLONE_CONF="$h2/.config/rclone/rclone.conf" \
          sh "$YD" get-config) || fail "get-config (старый формат) exit $?"
    printf '%s\n' "$out" | grep -qx "dir=/legacy"          || fail "старый формат: нет dir=/legacy: $out"
    printf '%s\n' "$out" | grep -qx "remote=yandexdisk:"   || fail "старый формат: remote не по умолчанию: $out"
    printf '%s\n' "$out" | grep -qx "token_configured=0"   || fail "старый формат: token_configured!=0 без rclone.conf: $out"
    ok "get-config: настроенный => поля+token_configured=1, секрет НЕ в выводе; старый config.cfg => дефолт remote, token=0"
}

t38_check_folder() {
    T=T38
    base="$WORK/t38"; mkdir -p "$base/realdir"; : > "$base/afile"
    e_h="$WORK/t38home"; e_v="$WORK/t38var"; e_c="$WORK/t38home/x"
    # (a) существующий каталог с правом записи => exists=1, writable=1, есть owner.
    out=$(YD_HOME="$e_h" YD_VAR="$e_v" YD_RCLONE_CONF="$e_c" sh "$YD" check-folder "$base/realdir") \
        || fail "check-folder(dir) exit $?"
    printf '%s\n' "$out" | grep -qx "exists=1"   || fail "realdir: нет exists=1: $out"
    printf '%s\n' "$out" | grep -qx "writable=1" || fail "realdir: нет writable=1: $out"
    printf '%s\n' "$out" | grep -q  "^owner="    || fail "realdir: нет строки owner=: $out"
    # (b) путь существует, но это ФАЙЛ (не каталог) => writable=0. root-устойчиво и
    # убивает мутант '&&'->'||' в [ -d ] && [ -w ] (для файла -d ложно, -w истинно).
    out=$(YD_HOME="$e_h" YD_VAR="$e_v" YD_RCLONE_CONF="$e_c" sh "$YD" check-folder "$base/afile") \
        || fail "check-folder(file) exit $?"
    printf '%s\n' "$out" | grep -qx "exists=1"   || fail "afile: нет exists=1: $out"
    printf '%s\n' "$out" | grep -qx "writable=0" || fail "afile (не каталог): нет writable=0: $out"
    # (c) несуществующий путь => exists=0, writable=0, owner=?.
    out=$(YD_HOME="$e_h" YD_VAR="$e_v" YD_RCLONE_CONF="$e_c" sh "$YD" check-folder "$base/nope") \
        || fail "check-folder(absent) exit $?"
    printf '%s\n' "$out" | grep -qx "exists=0"   || fail "nope: нет exists=0: $out"
    printf '%s\n' "$out" | grep -qx "writable=0" || fail "nope: нет writable=0: $out"
    printf '%s\n' "$out" | grep -qx "owner=?"    || fail "nope: owner!=? : $out"
    # (d) без аргумента => usage, rc=2.
    rc=0; YD_HOME="$e_h" YD_VAR="$e_v" YD_RCLONE_CONF="$e_c" sh "$YD" check-folder >/dev/null 2>&1 || rc=$?
    [ "$rc" = 2 ] || fail "check-folder без аргумента: rc=$rc, ожидался 2"
    ok "check-folder: каталог=>exists/writable=1; файл=>writable=0; отсутствует=>0/0/owner=?; без арг=>rc2"
}

# --- Phase 2: тонкий CGI settings.cgi (вкладка settings = имя CGI) -----------
# CGI — только парсер HTTP: разбирает метод/действие/тело и ДЕЛЕГИРУЕТ в обёртку
# yandex-disk (как на NAS). Эмулируем webman: REQUEST_METHOD/QUERY_STRING/CONTENT_LENGTH/
# stdin + SynoToken. YD_RUNAS= отключает sudo off-NAS (обёртка зовётся напрямую, YD_*-
# оверрайды доходят; sudo с env_reset их бы вычистил). Инварианты: токен только телом->
# stdin и НЕ в ответе; мутации требуют SynoToken (CSRF); get-config => JSON без токена.
CGI="$ROOT/spk/package/ui/scripts/settings.cgi"

# scgi <method> <query> <synotoken> <body> — вызвать settings.cgi как webman и напечатать
# его ответ. CONTENT_LENGTH считается в БАЙТАХ (важно для UTF-8). Тело идёт в stdin
# (секрет НЕ через argv процесса: printf — builtin, передача телом — в pipe). Окружение
# пакета — h/v/conf (как в остальных сценариях); RCLONE экспортирован глобально.
scgi() {
    _cl=$(printf '%s' "$4" | wc -c | tr -d ' ')
    printf '%s' "$4" | REQUEST_METHOD="$1" QUERY_STRING="$2" CONTENT_LENGTH="$_cl" \
        HTTP_X_SYNO_TOKEN="$3" YD_RUNAS='' \
        YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$conf" \
        sh "$CGI"
}

t39_settings_get_config() {
    T=T39
    h="$WORK/t39home"; v="$WORK/t39var"; loc="$WORK/t39local"; conf="$h/.config/rclone/rclone.conf"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$loc"
    secret="ya29.SENTINEL-DO-NOT-LEAK-CGI-GET"
    printf '[yandexdisk]\ntype = yandex\ntoken = {"access_token":"%s"}\n' "$secret" > "$conf"
    printf 'dir="%s"\nremote="yandexdisk:/Sub"\nclean_thumbs=1\n' "$loc" > "$h/.config/yandex-disk/config.cfg"
    out=$(scgi GET "action=get-config" "" "") || fail "settings.cgi GET get-config exit $?"
    printf '%s\n' "$out" | head -1 | grep -qi '^Content-Type: application/json' \
        || fail "get-config: нет заголовка application/json: $out"
    case "$out" in *"$secret"*) fail "СЕКРЕТ утёк в ответ settings.cgi get-config";; *) ;; esac
    printf '%s' "$out" | grep -qF "\"dir\":\"$loc\""           || fail "get-config JSON без dir=$loc: $out"
    printf '%s' "$out" | grep -qF '"remote":"yandexdisk:/Sub"' || fail "get-config JSON: неверный remote: $out"
    printf '%s' "$out" | grep -qF '"clean_thumbs":"1"'         || fail "get-config JSON: неверный clean_thumbs: $out"
    printf '%s' "$out" | grep -qF '"token_configured":true'    || fail "get-config JSON: token_configured!=true: $out"
    ok "settings.cgi GET get-config => application/json, поля верны, токен НЕ в ответе (только флаг true)"
}

t40_settings_set_folder() {
    T=T40
    h="$WORK/t40home"; v="$WORK/t40var"; loc="$WORK/t40local"; conf="$h/.config/rclone/rclone.conf"
    mkdir -p "$h/.config/yandex-disk" "$loc"
    cfgf="$h/.config/yandex-disk/config.cfg"
    # (a) валидное тело из 3 строк => делегирование set-folder => config.cfg (round-trip).
    body=$(printf '%s\nyandexdisk:/Backup\n1' "$loc")
    out=$(scgi POST "action=set-folder" syno "$body") || fail "set-folder exit $?"
    printf '%s' "$out" | grep -qF '"ok":true' || fail "set-folder: нет ok:true: $out"
    [ -f "$cfgf" ] || fail "set-folder: config.cfg не создан"
    [ "$(cfg_probe "$h" dir)" = "$loc" ]                  || fail "set-folder dir round-trip: $(cfg_probe "$h" dir)"
    [ "$(cfg_probe "$h" remote)" = "yandexdisk:/Backup" ] || fail "set-folder remote round-trip: $(cfg_probe "$h" remote)"
    [ "$(cfg_probe "$h" clean_thumbs)" = 1 ]              || fail "set-folder clean_thumbs round-trip"
    # (b) относительный dir => обёртка rc=2 => CGI Status 400, config.cfg НЕ перезаписан.
    before=$(cat "$cfgf")
    out=$(scgi POST "action=set-folder" syno "relative/path") || fail "set-folder(bad) exit $?"
    printf '%s\n' "$out" | head -1 | grep -qi '^Status: 400' || fail "относительный dir: нет Status 400: $out"
    printf '%s' "$out" | grep -qF '"ok":false' || fail "относительный dir: нет ok:false: $out"
    [ "$(cat "$cfgf")" = "$before" ] || fail "config.cfg перезаписан при отказе валидации"
    ok "settings.cgi POST set-folder: 3-строчное тело => config.cfg (round-trip); относительный путь => 400, конфиг цел"
}

t41_settings_set_token() {
    T=T41
    h="$WORK/t41home"; v="$WORK/t41var"; conf="$h/.config/rclone/rclone.conf"
    mkdir -p "$h/.config/rclone"
    secret="ya29.SENTINEL-SECRET-CGI-SET-TOKEN"
    body=$(printf '{"access_token":"%s","token_type":"OAuth"}' "$secret")
    out=$(scgi POST "action=set-token" syno "$body") || fail "set-token exit $?"
    case "$out" in *"$secret"*) fail "СЕКРЕТ утёк в ответ settings.cgi set-token";; *) ;; esac
    printf '%s' "$out" | grep -qF '"ok":true' || fail "set-token: нет ok:true: $out"
    [ -f "$conf" ] || fail "set-token: rclone.conf не создан"
    grep -q '^\[yandexdisk\]' "$conf" || fail "set-token: нет секции [yandexdisk]"
    grep -qF "$secret" "$conf"          || fail "set-token: токен не записан в rclone.conf"
    perm=$(ls -l "$conf" | awk 'NR==1{print $1}')
    case "$perm" in -rw-------*) ;; *) fail "rclone.conf режим не 0600: $perm";; esac
    ok "settings.cgi POST set-token: rclone.conf [yandexdisk]+токен 0600; секрет НЕ в ответе CGI"
}

t42_settings_check_folder() {
    T=T42
    h="$WORK/t42home"; v="$WORK/t42var"; conf="$h/.config/rclone/rclone.conf"
    mkdir -p "$h/.config/yandex-disk" "$WORK/t42dir"
    # существующий каталог => exists/writable true + owner.
    out=$(scgi POST "action=check-folder" syno "$WORK/t42dir") || fail "check-folder exit $?"
    printf '%s' "$out" | grep -qF '"exists":true'   || fail "check-folder(dir): нет exists:true: $out"
    printf '%s' "$out" | grep -qF '"writable":true' || fail "check-folder(dir): нет writable:true: $out"
    printf '%s' "$out" | grep -qF '"owner":'        || fail "check-folder(dir): нет owner: $out"
    # отсутствующий путь => exists/writable false.
    out=$(scgi POST "action=check-folder" syno "$WORK/t42missing") || fail "check-folder(absent) exit $?"
    printf '%s' "$out" | grep -qF '"exists":false'   || fail "check-folder(absent): нет exists:false: $out"
    printf '%s' "$out" | grep -qF '"writable":false' || fail "check-folder(absent): нет writable:false: $out"
    ok "settings.cgi POST check-folder => JSON exists/writable/owner (каталог true/true; отсутствует false/false)"
}

t43_settings_guards() {
    T=T43
    h="$WORK/t43home"; v="$WORK/t43var"; conf="$h/.config/rclone/rclone.conf"
    mkdir -p "$h/.config/yandex-disk"
    cfgf="$h/.config/yandex-disk/config.cfg"
    # (a) CSRF: POST set-folder БЕЗ SynoToken => 403, мутации нет (config.cfg не создан).
    out=$(scgi POST "action=set-folder" "" "/whatever") || fail "csrf-case exit $?"
    printf '%s\n' "$out" | head -1 | grep -qi '^Status: 403' || fail "POST без SynoToken: нет Status 403: $out"
    [ ! -f "$cfgf" ] || fail "мутация прошла без SynoToken (CSRF не сработал)"
    # (b) метод: GET на мутацию => 405; POST на чтение get-config => 405.
    out=$(scgi GET "action=set-folder" syno "") || fail "method-case1 exit $?"
    printf '%s\n' "$out" | head -1 | grep -qi '^Status: 405' || fail "GET set-folder: нет Status 405: $out"
    out=$(scgi POST "action=get-config" syno "") || fail "method-case2 exit $?"
    printf '%s\n' "$out" | head -1 | grep -qi '^Status: 405' || fail "POST get-config: нет Status 405: $out"
    # (c) неизвестное/пустое действие => 400.
    out=$(scgi GET "action=bogus" "" "") || fail "unknown-action exit $?"
    printf '%s\n' "$out" | head -1 | grep -qi '^Status: 400' || fail "неизвестное действие: нет Status 400: $out"
    out=$(scgi GET "" "" "") || fail "empty-action exit $?"
    printf '%s\n' "$out" | head -1 | grep -qi '^Status: 400' || fail "пустое действие: нет Status 400: $out"
    ok "settings.cgi гарды: POST без SynoToken=>403 (без мутации); GET-мутация/POST-чтение=>405; неизвестное=>400"
}

# T44 (регресс «HTTP 500: вкладка настроек не грузится / не сохраняет»): 3rdparty-CGI
# исполняется как САМ пользователь пакета sc-yandexdisk (conf/privilege: run-as: package;
# подтверждено diag.cgi euid=256139). Значит settings.cgi обязан звать обёртку НАПРЯМУЮ,
# без sudo/privilege-drop: sc-yandexdisk не может беспарольно sudo, и в контексте synoscgi
# sudo зависал -> весь дашборд падал в HTTP 500. Здесь на PATH кладём «отравленный» sudo
# (всегда exit 1): если бы settings.cgi звал sudo для ЛЮБОГО действия — оно бы упало.
# Чтение (get-config) И ЗАПИСЬ (set-token) обязаны пройти => CGI к sudo не обращается.
t44_settings_no_sudo() {
    T=T44
    h="$WORK/t44home"; v="$WORK/t44var"; conf="$h/.config/rclone/rclone.conf"; loc="$WORK/t44local"
    bin="$WORK/t44bin"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$loc" "$bin"
    printf 'dir="%s"\nremote="yandexdisk:"\n' "$loc" > "$h/.config/yandex-disk/config.cfg"
    # «Отравленный» sudo: любой его вызов = провал теста (settings.cgi не должен его звать).
    printf '#!/bin/sh\necho "sudo: poisoned (settings.cgi must not call sudo)" >&2\nexit 1\n' > "$bin/sudo"
    chmod +x "$bin/sudo"
    secret="ya29.SENTINEL-T44-DO-NOT-LEAK"
    # (a) READ get-config при отравленном sudo на PATH => 200 + конфиг (sudo не вызывался).
    out=$(printf '' | PATH="$bin:$PATH" REQUEST_METHOD=GET QUERY_STRING="action=get-config" CONTENT_LENGTH=0 \
        HTTP_X_SYNO_TOKEN="" YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$conf" sh "$CGI") || fail "get-config exit $?"
    printf '%s\n' "$out" | head -1 | grep -qi '^Content-Type: application/json' \
        || fail "get-config не отдал json/200 при отравленном sudo (CGI всё ещё зовёт sudo): $out"
    case "$out" in *"Status: 500"*) fail "get-config => 500 при отравленном sudo — CGI обращается к sudo";; esac
    printf '%s' "$out" | grep -qF "\"dir\":\"$loc\"" || fail "get-config без dir: $out"
    # (b) WRITE set-token при отравленном sudo => rclone.conf записан напрямую (sudo не вызывался).
    body=$(printf '{"access_token":"%s"}' "$secret")
    cl=$(printf '%s' "$body" | wc -c | tr -d ' ')
    out=$(printf '%s' "$body" | PATH="$bin:$PATH" REQUEST_METHOD=POST QUERY_STRING="action=set-token" \
        CONTENT_LENGTH="$cl" HTTP_X_SYNO_TOKEN="syno" \
        YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$conf" sh "$CGI") || fail "set-token exit $?"
    printf '%s' "$out" | grep -qF '"ok":true' || fail "set-token не прошёл при отравленном sudo (CGI зовёт sudo на записи?): $out"
    grep -q '^\[yandexdisk\]' "$conf" || fail "set-token не записал rclone.conf"
    case "$out" in *"$secret"*) fail "СЕКРЕТ утёк в ответ set-token";; esac
    ok "settings.cgi: чтение И запись идут БЕЗ sudo/privilege-drop (CGI=sc-yandexdisk; регресс HTTP 500 закрыт)"
}

# T45 (регресс «HTTP 500 через webman-симлинк»): DSM монтирует UI как симлинк
# /usr/syno/synoman/webman/3rdparty/YandexDisk -> /var/packages/YandexDisk/target/ui, и
# settings.cgi приходит через него. Путь к обёртке (YD_BIN) CGI вычисляет от $0; с
# ЛОГИЧЕСКИМ pwd симлинк не разворачивается, "scripts/../.." уводит в webman/3rdparty,
# YD_BIN -> несуществующий файл -> обёртка не вызвана -> HTTP 500 (наблюдалось на NAS).
# Прежние T39-T44 это НЕ ловили: они задают YD_BIN явно, минуя резолв. Здесь
# воспроизводим раскладку с симлинком и зовём CGI БЕЗ YD_BIN — резолв (pwd -P) обязан
# найти обёртку и вернуть конфиг.
t45_settings_via_webman_symlink() {
    T=T45
    tgt="$WORK/t45/target"; web="$WORK/t45/webman/3rdparty"
    h="$WORK/t45/home"; v="$WORK/t45/var"; conf="$h/.config/rclone/rclone.conf"
    mkdir -p "$tgt/ui/scripts" "$web" "$h/.config/rclone" "$h/.config/yandex-disk" "$v"
    ln -s "$ROOT/spk/package/yandex-disk"             "$tgt/yandex-disk"
    ln -s "$ROOT/spk/package/common.sh"              "$tgt/common.sh"
    ln -s "$RCLONE"                                   "$tgt/rclone"
    ln -s "$ROOT/spk/package/ui/scripts/settings.cgi" "$tgt/ui/scripts/settings.cgi"
    ln -s "$tgt/ui" "$web/YandexDisk"                 # как DSM: webman/3rdparty/YandexDisk -> target/ui
    printf 'dir="/volume1/work"\nremote="yandexdisk:"\n' > "$h/.config/yandex-disk/config.cfg"
    printf '[yandexdisk]\ntype = yandex\ntoken = {"access_token":"%s"}\n' "ya29.SENTINEL-T45" > "$conf"
    # Зов ЧЕРЕЗ СИМЛИНК и БЕЗ YD_BIN — резолв обёртки обязан сработать сам.
    out=$(printf '' | REQUEST_METHOD=GET QUERY_STRING='action=get-config' CONTENT_LENGTH=0 \
        YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$conf" \
        sh "$web/YandexDisk/scripts/settings.cgi" 2>&1) || fail "settings.cgi exit $?"
    printf '%s\n' "$out" | head -1 | grep -qi '^Content-Type: application/json' \
        || fail "через webman-симлинк CGI не отдал json/200 (YD_BIN не разрезолвился): $out"
    case "$out" in *"Status: 500"*) fail "через webman-симлинк => 500 (YD_BIN мимо обёртки)";; esac
    printf '%s' "$out" | grep -qF '"dir":"/volume1/work"' \
        || fail "через webman-симлинк get-config не вернул конфиг (обёртка не найдена): $out"
    printf '%s' "$out" | grep -qF '"token_configured":true' || fail "token_configured!=true: $out"
    case "$out" in *"ya29.SENTINEL-T45"*) fail "СЕКРЕТ утёк в ответ get-config";; esac
    ok "settings.cgi через webman-симлинк (без YD_BIN): YD_BIN резолвится (pwd -P), конфиг прочитан"
}

# --- Golden-снимки наблюдаемого контракта (test/golden/) --------------------
# Фиксируют ТОЧНЫЙ человекочитаемый вывод, который видят пользователь и UI.
# Переменные части нормализуются: путь WORK -> <WORK>, таймстемп -> <TS>.

norm() {
    sed -e "s#$WORK#<WORK>#g" \
        -e 's/[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9][0-9][0-9] - [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/<TS>/g'
}

# Как norm(), но дополнительно гасит машинно-зависимые строки diag (имя/uid/euid
# исполняющего пользователя), оставляя детерминированными каркас и вердикт.
norm_diag() {
    norm | sed -e 's/^whoami:.*$/whoami: <U>/' \
               -e 's/^id:.*$/id: <ID>/' \
               -e 's/^euid:.*$/euid: <N>/'
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

g05_diag_not_writable() {
    T=G5
    h="$WORK/g5home"
    mkdir -p "$h"
    : > "$h/.config"   # .config — файл => целевые каталоги не создаются (детерминированно)
    YD_HOME="$h" YD_VAR="$WORK/g5var" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
        sh "$YD" diag | norm_diag > "$WORK/actual"
    golden_cmp diag-not-writable.txt "$WORK/actual"
}

g06_get_config() {
    T=G6
    h="$WORK/g6home"; v="$WORK/g6var"; loc="$WORK/g6local"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$loc"
    # Токен-сентинел в conf: golden фиксирует, что get-config его НЕ печатает.
    printf '[yandexdisk]\ntype = yandex\ntoken = {"access_token":"SENTINEL"}\n' \
        > "$h/.config/rclone/rclone.conf"
    printf 'dir="%s"\nremote="yandexdisk:"\nclean_thumbs=0\n' "$loc" \
        > "$h/.config/yandex-disk/config.cfg"
    YD_HOME="$h" YD_VAR="$v" YD_RCLONE_CONF="$h/.config/rclone/rclone.conf" \
        sh "$YD" get-config | norm > "$WORK/actual"
    golden_cmp get-config.txt "$WORK/actual"
}

g07_settings_get_config() {
    T=G7
    h="$WORK/g7home"; v="$WORK/g7var"; loc="$WORK/g7local"; conf="$h/.config/rclone/rclone.conf"
    mkdir -p "$h/.config/rclone" "$h/.config/yandex-disk" "$loc"
    # Токен-сентинел в conf: golden фиксирует, что settings.cgi его НЕ печатает (флаг true).
    printf '[yandexdisk]\ntype = yandex\ntoken = {"access_token":"SENTINEL"}\n' > "$conf"
    printf 'dir="%s"\nremote="yandexdisk:"\nclean_thumbs=0\n' "$loc" > "$h/.config/yandex-disk/config.cfg"
    scgi GET "action=get-config" "" "" | norm > "$WORK/actual"
    golden_cmp settings-get-config.txt "$WORK/actual"
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
t14_version_cache
t15_auto_recover_alt_trigger
t16_configured_needs_dir
t17_resolve_remote_ambiguous
t18_subcommand_routing
t19_rotate_boundary
t20_clean_thumbs
t21_first_run_resync_fail
t22_setup_output
t23_configured_needs_section
t24_diag_writable
t25_diag_not_writable
t26_diag_no_secret_leak
t27_diag_cgi_delegates
t28_validate_dir
t29_validate_remote
t30_validate_token
t31_is_token_configured
t32_set_folder_writes
t33_set_folder_rejects
t34_set_folder_write_fail
t35_set_token_writes
t36_set_token_rejects
t37_get_config
t38_check_folder
t39_settings_get_config
t40_settings_set_folder
t41_settings_set_token
t42_settings_check_folder
t43_settings_guards
t44_settings_no_sudo
t45_settings_via_webman_symlink
g01_status_configured
g02_status_unconfigured
g03_state_line_7field
g04_state_line_3field
g05_diag_not_writable
g06_get_config
g07_settings_get_config

echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
