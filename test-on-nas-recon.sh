#!/bin/sh
# test-on-nas-recon.sh — единый разведчик NAS для задачи
#   «самопроверка пакета при установке + план отказа/отката»
#   (docs/proposal-install-self-check.md §12 ⚠ВЕРИФ).
#
# Снимает РАЗОМ все факты, нужные перед написанием preinst/postinst.
# Это ОДНОРАЗОВЫЙ инструмент разведки, НЕ часть релиза. В рабочий .spk не паковать.
#
# ── Два режима (один файл) ────────────────────────────────────────────────
# (A) Ручной отчёт по SSH (контекст окружения):
#       sudo sh test-on-nas-recon.sh report
#     Печатает: arch хоста vs e_machine бинаря rclone (arch-agnostic, §10-8),
#     пользователь пакета, владелец/право-на-запись $VAR_DIR/logs, место на томе,
#     смоук обёртки под sc-yandexdisk, опц. связь с Яндексом (§4.2), хвост
#     synopkg.log (R5), и СВОДКУ снимков, собранных в режиме (B).
#
# (B) Lifecycle-хук внутри throwaway debug-.spk (контекст DSM):
#     скопируйте ЭТОТ файл в spk/scripts/preinst, postinst, preupgrade,
#     postupgrade debug-сборки — он определяет фазу по basename "$0".
#     DSM вызовет его на установке/апгрейде → он логирует контекст фазы
#     (id, uname -m, SYNOPKG_*, sc-yandexdisk, запись в logs) в стабильный
#     лог (/tmp/yd-recon.log) и в stdout (→ /var/log/synopkg.log).
#     Падение по требованию (тест плана отката §5): перечислите фазы в файле-
#     триггере, напр.  echo postinst > /tmp/yd-recon.fail  → хук сделает
#     exit 1 на этой фазе. Удалить триггер — вернуться к exit 0.
#
# Все факты структурные, без секретов (токен/rclone.conf не читаются).
# ──────────────────────────────────────────────────────────────────────────

set -u

RECON_LOG="${YD_RECON_LOG:-/tmp/yd-recon.log}"
FAIL_FILE="${YD_RECON_FAIL:-/tmp/yd-recon.fail}"
PKG="${YD_PKG_DIR:-/var/packages/YandexDisk}"
VAR_DIR="$PKG/var"
LOG_DIR="$VAR_DIR/logs"
PKG_USER="sc-yandexdisk"

RCLONE="/usr/local/bin/rclone";  [ -x "$RCLONE" ] || RCLONE="$PKG/target/rclone"
YD="/usr/local/bin/yandex-disk"; [ -x "$YD" ]     || YD="$PKG/target/yandex-disk"

# ── helpers ───────────────────────────────────────────────────────────────

# durable best-effort log: stdout (→ synopkg.log) + общий файл (chmod 666, чтобы
# дописывали и root, и sc-yandexdisk на разных фазах lifecycle).
_log() {
    printf '%s\n' "$*"
    if [ ! -e "$RECON_LOG" ]; then
        ( touch "$RECON_LOG" && chmod 666 "$RECON_LOG" ) 2>/dev/null || true
    fi
    ( printf '%s\n' "$*" >> "$RECON_LOG" ) 2>/dev/null || true
}

# uname -m → ожидаемый ELF e_machine (arch-agnostic, §10-8): сверяемся с ХОСТОМ,
# а не с константой 183 — иначе завалили бы каждую x86_64-установку.
expected_em() {
    case "$(uname -m)" in
        aarch64|arm64)      echo 183 ;;
        x86_64|amd64)       echo 62  ;;
        armv7l|armv7|armhf) echo 40  ;;
        *)                  echo "?" ;;
    esac
}

# e_machine бинаря из ELF-заголовка (offset 18) — та же техника, что build.sh:190.
bin_em() { od -An -tu1 -j18 -N1 "$1" 2>/dev/null | tr -d ' '; }

arch_verdict() {
    _bin="$1"
    [ -e "$_bin" ] || { echo "rclone отсутствует: $_bin"; return; }
    _exp="$(expected_em)"; _got="$(bin_em "$_bin")"
    if [ "$_exp" = "$_got" ]; then
        echo "OK: e_machine=$_got совпадает с host ($(uname -m))"
    else
        echo "MISMATCH: bin e_machine=$_got, host ожидает $_exp ($(uname -m)) — ЭТО завалило бы установку"
    fi
}

write_probe() {
    _dir="$1"; _p="$_dir/.recon_probe.$$"
    if ( mkdir -p "$_dir" && printf 'probe\n' > "$_p" ) 2>/dev/null; then
        rm -f "$_p" 2>/dev/null || true
        echo "OK (есть право записи)"
    else
        echo "FAIL (нет каталога/прав на этой фазе)"
    fi
}

# ── режим B: снимок фазы lifecycle ────────────────────────────────────────
snapshot() {
    _ph="$1"
    _log "================ RECON phase=$_ph $(date '+%F %T' 2>/dev/null) ================"
    _log "pkgver:     OLD='${SYNOPKG_OLD_PKGVER:-<unset>}'  NEW='${SYNOPKG_PKGVER:-<unset>}'"
    _log "whoami:     $(id 2>&1)"                          # R3: root или sc-yandexdisk
    _log "host-arch:  $(uname -m)  -> ожид. e_machine $(expected_em)"  # R1/§10-8
    _log "sc-user:    $(id "$PKG_USER" 2>&1)"              # R3a: когда DSM создаёт юзера
    _log "VAR_DIR:    $(ls -ld "$VAR_DIR" 2>&1)"           # §4.2 / §12-2
    _log "LOG_DIR:    $(ls -ld "$LOG_DIR" 2>&1)"
    _log "logs-write: $(write_probe "$LOG_DIR")"           # R4
    _log "rclone:     $(ls -l "$RCLONE" 2>&1)"
    _log "rclone-arch:$(arch_verdict "$RCLONE")"           # R1/§10-8
    _log "--- env SYNOPKG_* ---"                           # R6: имена, есть ли OLD_PKGVER
    env | grep '^SYNOPKG' | sort | while IFS= read -r _l; do _log "  $_l"; done
    # R5: заметный многострочный маркер в stderr — посмотреть, сколько покажет UI.
    printf '%s\n' "RECON[$_ph]: STDERR-MARKER-1" \
                  "RECON[$_ph]: STDERR-MARKER-2" \
                  "RECON[$_ph]: STDERR-MARKER-3 (последняя)" >&2
    _log "--- end phase=$_ph ---"; _log ""
}

maybe_fail() {
    _ph="$1"
    [ -f "$FAIL_FILE" ] || return 0
    if grep -qw "$_ph" "$FAIL_FILE" 2>/dev/null; then
        _log "!!! RECON: умышленный FAIL фазы=$_ph (по $FAIL_FILE) -> exit 1"
        printf '%s\n' "RECON: умышленный отказ фазы $_ph (тест плана отката §5)" >&2
        exit 1
    fi
}

# ── режим A: сводный отчёт ────────────────────────────────────────────────
report() {
    echo "########## NAS RECON REPORT $(date '+%F %T' 2>/dev/null) ##########"
    echo "[host ]  uname -m=$(uname -m)  -> ожид. e_machine $(expected_em)"
    echo "[host ]  $(uname -a)"
    echo "[pkg  ]  synopkg status YandexDisk:"
    synopkg status YandexDisk 2>&1 | sed 's/^/         /'
    echo "[user ]  $(id "$PKG_USER" 2>&1)"
    echo "[var  ]  $(ls -ld "$VAR_DIR" 2>&1)"
    echo "[logs ]  $(ls -ld "$LOG_DIR" 2>&1)"
    echo "[logsW]  $(write_probe "$LOG_DIR")"
    echo "[space]  df тома установки:"
    df -h "$PKG" 2>&1 | sed 's/^/         /'
    echo "[rcln ]  $(ls -l "$RCLONE" 2>&1)"
    if [ -x "$RCLONE" ]; then
        echo "[rcln ]  version: $("$RCLONE" version 2>&1 | head -1)"
        echo "[rcln ]  arch:    $(arch_verdict "$RCLONE")"
    fi
    echo "[wrap ]  смоук обёртки под $PKG_USER (R3 — нужен ли sudo -u):"
    if [ -x "$YD" ]; then
        sudo -u "$PKG_USER" "$YD" version 2>&1 | head -2 | sed 's/^/         /' \
            || echo "         (sudo -u не сработал — занести в R3)"
    else
        echo "         обёртка не найдена: $YD"
    fi
    echo "[net  ]  опц. связь с Яндексом (мягко, §4.2 — провал НЕ валит install):"
    if command -v curl >/dev/null 2>&1; then
        curl -s -m 3 -o /dev/null -w "         curl webdav.yandex.ru -> HTTP %{http_code}\n" \
            https://webdav.yandex.ru 2>/dev/null || echo "         нет связи (не критично)"
    elif command -v ping >/dev/null 2>&1; then
        ping -c1 -W3 ya.ru >/dev/null 2>&1 && echo "         ping ya.ru OK" \
            || echo "         нет связи (не критично)"
    else
        echo "         ни curl, ни ping недоступны"
    fi
    echo
    echo "########## LIFECYCLE SNAPSHOTS (режим B) :: $RECON_LOG ##########"
    if [ -s "$RECON_LOG" ]; then cat "$RECON_LOG"
    else echo "(пусто — ещё не было install/upgrade c debug-.spk)"; fi
    echo
    echo "########## ХВОСТ synopkg.log (R5: что видит Package Center) ##########"
    tail -n 60 /var/log/synopkg.log 2>&1
}

# ── диспетчер: фаза = basename "$0", иначе ручной режим ────────────────────
case "$(basename "$0")" in
    preinst|postinst|preupgrade|postupgrade)
        _phase="$(basename "$0")"
        snapshot "$_phase"
        maybe_fail "$_phase"
        exit 0 ;;
    *)
        case "${1:-report}" in
            report|"") report ;;
            *) echo "usage: $0 report   (или установить как lifecycle-хук preinst/postinst/preupgrade/postupgrade)" >&2
               exit 2 ;;
        esac ;;
esac
