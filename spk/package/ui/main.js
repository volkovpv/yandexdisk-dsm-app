(() => {
  "use strict";
  const VueRef = Vue;

  // ───────────────────────────────────────────────────────────────────────────
  // Дашборд пакета «Яндекс Диск» (Phase 3, docs/ui-config-migration-plan.md §7).
  //
  // Раскладка — мастер-детейл по образцу Synology Hyper Backup (design/spec.md,
  // эталон вёрстки design/prototype/index.html): слева боковая панель со списком
  // папок, справа детали (шапка статуса + две карточки). Тонкий клиент: вся
  // запись/чтение конфигов делегируется обёртке yandex-disk через CGI (канон:
  // общая логика — только в common.sh). UI НЕ дублирует ни путей, ни валидации.
  //
  // Контракты канона, сохраняемые здесь:
  //   • ключ вкладки = имя CGI: status / log / sync_log + новый settings;
  //   • имя remote «yandexdisk» фиксировано (меняется только подпапка);
  //   • токен НИКОГДА не отображается — только флаг token_configured.
  //
  // Объём v1 (MVP, design/spec.md §6,§7): одна папка («+» неактивна при наличии
  // папки), Tier 1 подключения (вставка JSON-токена), Опция A расписания (ручная
  // задача в Планировщике задач DSM). Approval-gated и показываются НЕАКТИВНЫМИ с
  // плашкой «вне MVP»: Tier 2 «Войти через Яндекс» и поле интервала (Опция B).
  // ───────────────────────────────────────────────────────────────────────────

  const BASE = "/webman/3rdparty/YandexDisk/scripts/";

  // Готовая к копированию команда задачи Планировщика (Опция A, план §3.3). Путь —
  // /usr/local/bin symlink обёртки (см. заголовок spk/package/yandex-disk).
  const SYNC_CMD = 'sudo -u sc-yandexdisk /usr/local/bin/yandex-disk sync';

  // Словарь статусов: ЕДИНСТВЕННОЕ место маппинга строк бэкенда -> визуального
  // состояния (design/spec.md §2). Источник строк — sync.state через status.cgi:
  // успех пишется как «idle|…|ok|…», ошибка как «error|…|<rc>» (yandex-disk
  // run_bisync/write_sync_state). Отсутствие sync.state -> «ещё не выполнялась».
  // warning/syncing на сегодня не используются: warning — задел под частичный успех;
  // syncing остался в словаре, но кнопка «Синхронизировать сейчас» работает fire-and-forget
  // (лишь стартует фоновый прогон, см. syncNow) и спиннер-состояние НЕ включает.
  const STATUS = {
    success:  { label: "Успешно",                    cls: "yd-st-success",  icon: "check" },
    warning:  { label: "Предупреждение",             cls: "yd-st-warning",  icon: "warn"  },
    error:    { label: "Ошибка синхронизации",       cls: "yd-st-error",    icon: "cross" },
    syncing:  { label: "Синхронизация…",             cls: "yd-st-syncing",  icon: null    },
    awaiting: { label: "Ожидает первой синхронизации", cls: "yd-st-awaiting", icon: "clock" },
  };

  // Иконки Feather (MIT), отрисовка через currentColor. Константные строки —
  // безопасны для innerHTML (никаких пользовательских данных, см. YdIcon).
  const ICONS = {
    folder: '<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>',
    plus:   '<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>',
    log:    '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/>',
    sync:   '<polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>',
    clock:  '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
    gear:   '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
    trash:  '<polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/><line x1="10" y1="11" x2="10" y2="17"/><line x1="14" y1="11" x2="14" y2="17"/>',
    check:  '<polyline points="20 6 9 17 4 12"/>',
    cross:  '<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>',
    warn:   '<line x1="12" y1="5" x2="12" y2="14"/><line x1="12" y1="18" x2="12" y2="18.01"/>',
    cloud:  '<path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/>',
  };

  // ─── CSRF (план §6/§7, design/spec.md §4) ─────────────────────────────────
  // Мутации settings.cgi требуют DSM SynoToken. При ВКЛЮЧЁННОЙ защите от CSRF
  // (Панель управления → Безопасность) webman режет POST без валидного токена СВОЕЙ
  // страницей 403 (HTML) — ещё ДО CGI; фронт давился ею в r.json() как «Некорректный
  // ответ сервера», и не работали ни «Синхронизировать сейчас», ни set-folder/set-token/
  // check-folder. Надёжный источник токена уже залогиненной сессии (подтверждено на DSM 7)
  // — /webman/login.cgi?enable_syno_token=yes: по сессионной cookie, БЕЗ логина/пароля,
  // отдаёт {"SynoToken":…,"success":true}. Тянем один раз и кэшируем на жизнь страницы;
  // SDS-API/глобаль/cookie оставлены быстрыми фолбэками для сборок, где они доступны.
  // Пустой результат НЕ кэшируем — чтобы дать шанс повторной попытке.
  let _csrfToken = null;
  async function synoToken() {
    if (_csrfToken) return _csrfToken;
    try {
      if (window.SYNO && SYNO.SDS && SYNO.SDS.Session && typeof SYNO.SDS.Session.getToken === "function") {
        const t = SYNO.SDS.Session.getToken();
        if (t) return (_csrfToken = t);
      }
    } catch (e) { /* SUI-контекст недоступен вне DSM — пробуем дальше */ }
    try { if (window._SYNO_TOKEN) return (_csrfToken = window._SYNO_TOKEN); } catch (e) { /* ignore */ }
    try {
      const r = await fetch("/webman/login.cgi?enable_syno_token=yes", { credentials: "same-origin" });
      const d = await r.json().catch(() => null);
      if (d && d.SynoToken) return (_csrfToken = d.SynoToken);
    } catch (e) { /* эндпоинта может не быть на иных сборках — пробуем cookie */ }
    const m = (document.cookie || "").match(/(?:^|;\s*)SynoToken=([^;]+)/);
    return m ? (_csrfToken = decodeURIComponent(m[1])) : "";
  }

  // GET текстового CGI (status.cgi / log.cgi / sync_log.cgi) — существующие
  // эндпоинты данных, контракт «ключ вкладки = имя CGI» сохранён. cache:"no-store" —
  // это динамика: у status.cgi нет анти-кэш заголовков, и без этого браузер мог бы
  // подсунуть из кэша старое состояние при перечитывании (loadAll на mount/переоткрытии).
  async function getText(name) {
    const r = await fetch(BASE + name, { credentials: "same-origin", cache: "no-store" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r.text();
  }

  // GET settings.cgi?action=… -> JSON. Без мутации, CSRF не нужен. cache:"no-store" —
  // конфиг читаем всегда свежим (после set-folder/set-token перечитываем через loadAll).
  async function settingsGet(action) {
    const r = await fetch(BASE + "settings.cgi?action=" + action, { credentials: "same-origin", cache: "no-store" });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.error || ("HTTP " + r.status));
    return data;
  }

  // POST settings.cgi?action=… с телом (сырые байты: UTF-8/пробелы в пути целы,
  // токен — вербатим в stdin set-token, см. settings.cgi). Несём SynoToken и в
  // заголовке, и параметром (CGI принимает любой). Бросает на !ok.
  async function settingsPost(action, body) {
    const tok = await synoToken();
    let url = BASE + "settings.cgi?action=" + action;
    if (tok) url += "&SynoToken=" + encodeURIComponent(tok);
    const headers = { "Content-Type": "text/plain; charset=utf-8" };
    if (tok) headers["X-SYNO-TOKEN"] = tok;
    const r = await fetch(url, {
      method: "POST", credentials: "same-origin", headers, body: body == null ? "" : body,
    });
    const data = await r.json().catch(() => ({ ok: false, error: "Некорректный ответ сервера" }));
    if (!r.ok || data.ok === false) throw new Error(data.error || ("HTTP " + r.status));
    return data;
  }

  // Разбор человекочитаемого вывода status.cgi (формат — контракт sync_state_line()
  // в common.sh, golden test/golden/status-configured.txt). Достаём время, строки
  // status/result и счётчики; «ещё не выполнялась» => neverRun.
  function parseStatus(text) {
    const st = { neverRun: true, ts: "", status: "", result: "", sent: 0, received: 0, modified: 0, deleted: 0 };
    const m = (text || "").match(/Последняя синхронизация:\s*([^\n]+)/);
    if (m) {
      const rest = m[1].trim();
      if (/ещё не выполнялась/i.test(rest)) {
        st.neverRun = true;
      } else {
        const mm = rest.match(/^(.*?)\s*\(([^/)]+)\/([^)]+)\)/);
        st.neverRun = false;
        if (mm) { st.ts = mm[1].trim(); st.status = mm[2].trim(); st.result = mm[3].trim(); }
        else { st.ts = rest; }
      }
    }
    const c = (text || "").match(/отправлено\):\s*(\d+);[^;]*получено\):\s*(\d+);\s*изменено:\s*(\d+);\s*удалено:\s*(\d+)/);
    if (c) { st.sent = +c[1]; st.received = +c[2]; st.modified = +c[3]; st.deleted = +c[4]; }
    return st;
  }

  // Маппинг разобранного состояния -> ключ STATUS (единый словарь, design §2).
  function visualOf(st) {
    if (!st || st.neverRun) return "awaiting";
    if (st.status === "error") return "error";
    if (st.result === "ok" || st.status === "idle") return "success";
    return "warning";
  }

  // ─── Мелкие компоненты ────────────────────────────────────────────────────
  // SVG-иконка из ICONS по имени. innerHTML — только КОНСТАНТНЫЕ строки ICONS,
  // пользовательских данных тут нет (XSS невозможен), поэтому domProps безопасен.
  const YdIcon = VueRef.extend({
    functional: true,
    props: { name: String },
    render(h, ctx) {
      return h("svg", {
        staticClass: "yd-ic",
        attrs: {
          viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
          "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round",
        },
        domProps: { innerHTML: ICONS[ctx.props.name] || "" },
      });
    },
  });

  // Круглый бейдж статуса (маленький в списке / большой в шапке). Спиннер для
  // syncing, иначе цветной кружок с иконкой из словаря STATUS.
  const StatusBadge = VueRef.extend({
    components: { YdIcon },
    props: { state: { type: String, default: "awaiting" }, big: Boolean },
    computed: { info() { return STATUS[this.state] || STATUS.awaiting; } },
    template: `
      <span :class="[big ? 'yd-big-badge' : 'yd-badge', info.cls]">
        <span v-if="state === 'syncing'" class="yd-spinner" :class="{ big: big }"></span>
        <yd-icon v-else :name="info.icon"></yd-icon>
      </span>`,
  });

  // ─── Главный компонент ────────────────────────────────────────────────────
  const App = VueRef.extend({
    name: "App",
    components: { YdIcon, StatusBadge },
    data() {
      return {
        loading: true,
        error: null,
        // Преднаполнение формы и карточек — из get-config (без значения токена).
        config: { dir: "", remote: "yandexdisk:", clean_thumbs: "0", interval: "", token_configured: false },
        // Разобранное состояние последней синхронизации (из status.cgi).
        state: { neverRun: true, ts: "", status: "", result: "", sent: 0, received: 0, modified: 0, deleted: 0 },
        visualStatus: "awaiting",
        folderOwner: "",
        syncing: false,
        syncError: null,
        syncMsg: null,   // подтверждение «синхронизация запущена» (fire-and-forget)
        // Модалки: null | 'dialog' | 'log' | 'history'.
        modal: null,
        dialogMode: "add",
        logText: "",
        historyText: "",
        // Состояние формы диалога.
        form: { dir: "", remote: "yandexdisk:", cleanThumbs: false, token: "", showToken: true },
        folderCheck: { checking: false, checked: false, exists: false, writable: false, owner: "" },
        fieldErr: { dir: "", remote: "", token: "" },
        formError: null,
        saving: false,
        tokenSaving: false,
        syncCmd: SYNC_CMD,
      };
    },
    computed: {
      // v1: «папка есть», если задан dir (один config.cfg — design §6).
      hasFolder() { return !!(this.config && this.config.dir); },
      folderName() {
        const d = this.config.dir || "";
        const parts = d.replace(/\/+$/, "").split("/");
        return parts[parts.length - 1] || d || "Папка";
      },
      statusInfo() { return STATUS[this.visualStatus] || STATUS.awaiting; },
      connected() { return !!this.config.token_configured; },
      canSync() { return this.hasFolder && this.connected && !this.syncing; },
      scheduleLabel() {
        return this.config.interval ? "Каждые " + this.config.interval + " мин" : "По Планировщику задач DSM";
      },
      lastResultLine() {
        if (this.state.neverRun) return "—";
        return "Отправлено: " + this.state.sent + " · Получено: " + this.state.received +
               " · Изменено: " + this.state.modified + " · Удалено: " + this.state.deleted;
      },
      addTitle() {
        return this.hasFolder ? "В этой версии поддерживается одна папка" : "Добавить папку";
      },
    },
    mounted() {
      this.loadAll();
    },
    methods: {
      // Параллельно тянем конфиг и статус, затем (необязательно) владельца папки.
      async loadAll() {
        this.loading = true;
        this.error = null;
        try {
          const [cfg, statusText] = await Promise.all([settingsGet("get-config"), getText("status.cgi")]);
          this.config = {
            dir: cfg.dir || "",
            remote: cfg.remote || "yandexdisk:",
            clean_thumbs: cfg.clean_thumbs || "0",
            interval: cfg.interval || "",
            token_configured: !!cfg.token_configured,
          };
          this.state = parseStatus(statusText);
          this.visualStatus = visualOf(this.state);
          this.folderOwner = "";
          if (this.config.dir) this.fetchOwner();
        } catch (e) {
          this.error = (e && e.message) || "Не удалось загрузить состояние";
        } finally {
          this.loading = false;
        }
      },
      // Владелец локальной папки — справочная строка карточки «Папка». Достаём
      // через check-folder (только чтение); ошибка/нет CSRF не должны ронять
      // дашборд, поэтому best-effort и молча игнорируем сбой.
      async fetchOwner() {
        try {
          const r = await settingsPost("check-folder", this.config.dir);
          if (r && r.owner && r.owner !== "?") this.folderOwner = r.owner;
        } catch (e) { /* owner необязателен */ }
      },
      // «Синхронизировать сейчас» — fire-and-forget. settings.cgi запускает тот же sync, что и
      // Планировщик задач, ОТВЯЗАННЫМ процессом и отвечает сразу. UI лишь СТАРТУЕТ прогон и НЕ
      // ждёт его: полный bisync большой папки идёт минутами, окну незачем висеть со спиннером.
      // По успеху показываем «запущена, идёт в фоне»; результат пользователь увидит позже,
      // переоткрыв окно (на mount loadAll перечитает status.cgi). Так же ведёт себя запуск из
      // Планировщика задач — он просто работает в фоне, а статус смотрят отдельно.
      async syncNow() {
        if (!this.canSync) return;
        this.syncing = true;        // кратко гасим кнопку на время POST (~30 мс)
        this.syncError = null;
        this.syncMsg = null;
        try {
          await settingsPost("sync", "");   // стартует фоновый прогон и СРАЗУ возвращается
          this.syncMsg = "Синхронизация запущена — выполняется в фоне. Обновите окно позже, чтобы увидеть результат, или откройте журнал rclone.";
        } catch (e) {
          this.syncError = (e && e.message) || "Не удалось запустить синхронизацию";
        } finally {
          this.syncing = false;
        }
      },

      // ── Модалки ────────────────────────────────────────────────────────────
      closeModal() { this.modal = null; },
      async openLog() {
        this.modal = "log";
        this.logText = "Загрузка…";
        try { this.logText = await getText("sync_log.cgi"); }
        catch (e) { this.logText = "Не удалось загрузить журнал: " + ((e && e.message) || e); }
      },
      async openHistory() {
        this.modal = "history";
        this.historyText = "Загрузка…";
        try { this.historyText = await getText("log.cgi"); }
        catch (e) { this.historyText = "Не удалось загрузить историю: " + ((e && e.message) || e); }
      },
      // Очистка истории состояний — существующий clear_log.cgi. Это POST, значит под
      // включённой CSRF-защитой webman тоже требует SynoToken (иначе 403) — несём его,
      // как в settingsPost. Сам журнал rclone не трогаем (самоочищается, нужен для диагностики).
      async clearHistory() {
        if (!confirm("Очистить историю синхронизации?")) return;
        try {
          const tok = await synoToken();
          let url = BASE + "clear_log.cgi";
          if (tok) url += "?SynoToken=" + encodeURIComponent(tok);
          await fetch(url, {
            method: "POST", credentials: "same-origin",
            headers: tok ? { "X-SYNO-TOKEN": tok } : {},
          });
          this.historyText = await getText("log.cgi");
        } catch (e) {
          alert("Ошибка очистки: " + ((e && e.message) || e));
        }
      },

      // ── Диалог добавления/редактирования ───────────────────────────────────
      onAddClick() { if (!this.hasFolder) this.openDialog("add"); }, // v1: «+» неактивна при наличии папки
      openDialog(mode) {
        this.dialogMode = mode;
        this.formError = null;
        this.fieldErr = { dir: "", remote: "", token: "" };
        this.saving = false;
        this.tokenSaving = false;
        this.folderCheck = { checking: false, checked: false, exists: false, writable: false, owner: "" };
        if (mode === "edit" && this.hasFolder) {
          this.form = {
            dir: this.config.dir,
            remote: this.config.remote,
            cleanThumbs: this.config.clean_thumbs === "1",
            token: "",
            showToken: !this.config.token_configured, // настроен -> поле скрыто до «Заменить токен»
          };
        } else {
          this.form = { dir: "", remote: "yandexdisk:", cleanThumbs: false, token: "", showToken: true };
        }
        this.modal = "dialog";
        if (this.form.dir) this.$nextTick(() => this.checkFolder());
      },
      // Живая проверка папки (debounce на ввод, сразу на blur): exists/writable/owner.
      scheduleCheck() {
        clearTimeout(this._ct);
        this._ct = setTimeout(() => this.checkFolder(), 350);
      },
      async checkFolder() {
        const dir = this.form.dir;
        if (!dir) { this.folderCheck = { checking: false, checked: false, exists: false, writable: false, owner: "" }; return; }
        this.folderCheck.checking = true;
        try {
          const r = await settingsPost("check-folder", dir);
          this.folderCheck = {
            checking: false, checked: true,
            exists: !!r.exists, writable: !!r.writable, owner: r.owner || "",
          };
        } catch (e) {
          this.folderCheck = { checking: false, checked: false, exists: false, writable: false, owner: "" };
        }
      },
      // Подключить токен немедленно (кнопка «Подключить»). Источник истины валидации —
      // обёртка (validate_token); тут лишь зеркалим пустой ввод для мгновенного отклика.
      async connectToken() {
        this.fieldErr.token = "";
        if (this.form.token.trim() === "") {
          this.fieldErr.token = 'Вставьте JSON-токен из rclone authorize "yandex".';
          return;
        }
        this.tokenSaving = true;
        try {
          await settingsPost("set-token", this.form.token);
          this.config.token_configured = true;
          this.form.token = "";
          this.form.showToken = false;
        } catch (e) {
          this.fieldErr.token = (e && e.message) || "Не удалось сохранить токен";
        } finally {
          this.tokenSaving = false;
        }
      },
      // Сохранить: set-folder, затем (если введён токен) set-token. Лёгкая
      // клиентская валидация зеркалит правила обёртки (validate_dir/validate_remote)
      // для мгновенного отклика; окончательный отказ — всё равно от обёртки.
      async save() {
        this.formError = null;
        this.fieldErr = { dir: "", remote: "", token: "" };
        const dir = (this.form.dir || "").trim();
        const remote = (this.form.remote || "").trim() || "yandexdisk:";
        if (!/^\//.test(dir) || /\n/.test(dir) || /"/.test(dir) || / #/.test(dir)) {
          this.fieldErr.dir = 'Укажите абсолютный путь (с «/») без символов " и подстроки « #».';
          return;
        }
        if (!/^[A-Za-z0-9_-]+:(\/.*)?$/.test(remote)) {
          this.fieldErr.remote = "Формат: NAME: или NAME:/подпапка (например, yandexdisk:/Backup).";
          return;
        }
        this.saving = true;
        try {
          await settingsPost("set-folder", dir + "\n" + remote + "\n" + (this.form.cleanThumbs ? "1" : "0"));
          if (this.form.showToken && this.form.token.trim() !== "") {
            await settingsPost("set-token", this.form.token);
          }
          await this.loadAll();
          this.closeModal();
        } catch (e) {
          this.formError = (e && e.message) || "Не удалось сохранить настройки";
        } finally {
          this.saving = false;
        }
      },
      copySyncCmd() {
        try {
          if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(this.syncCmd);
        } catch (e) { /* буфер обмена может быть недоступен — это не ошибка */ }
      },
    },
    template: `
      <v-app-instance class-name="SYNOCOMMUNITY.YandexDisk.AppInstance">
        <v-app-window
          ref="appWindow"
          syno-id="SYNOCOMMUNITY.YandexDisk.Window"
          :width="960"
          :height="600"
          :min-width="760"
          :min-height="460"
          :resizable="true"
        >
          <div class="yd-app">

            <!-- ───── Боковая панель ───── -->
            <div class="yd-sidebar">
              <div class="yd-sb-toolbar">
                <button
                  class="yd-tool-btn"
                  :class="{ primary: !hasFolder, disabled: hasFolder }"
                  :title="addTitle"
                  @click="onAddClick"
                >
                  <yd-icon name="plus"></yd-icon>
                </button>
                <button class="yd-tool-btn" title="Журнал rclone" @click="openLog">
                  <yd-icon name="log"></yd-icon>
                </button>
              </div>
              <div class="yd-folder-list">
                <div v-if="hasFolder" class="yd-folder-item active">
                  <span class="yd-fi-icon"><yd-icon name="folder"></yd-icon></span>
                  <span class="yd-fi-name">{{ folderName }}</span>
                  <status-badge :state="visualStatus"></status-badge>
                </div>
              </div>
            </div>

            <!-- ───── Детали ───── -->
            <div class="yd-detail">

              <div v-if="loading" class="yd-empty-state">
                <div class="yd-empty-text">Загрузка…</div>
              </div>

              <div v-else-if="error" class="yd-empty-state">
                <div class="yd-empty-title">Не удалось загрузить</div>
                <div class="yd-empty-text">{{ error }}</div>
                <button class="yd-btn yd-btn-secondary" @click="loadAll">Повторить</button>
              </div>

              <!-- Первый запуск: папок нет -->
              <div v-else-if="!hasFolder" class="yd-empty-state">
                <div class="yd-empty-illu">
                  <yd-icon name="folder"></yd-icon>
                  <span class="yd-empty-plus"><yd-icon name="plus"></yd-icon></span>
                </div>
                <div class="yd-empty-title">Папок пока нет</div>
                <div class="yd-empty-text">
                  Нажмите «Добавить папку», чтобы настроить первую синхронизацию с Яндекс Диском —
                  полностью из интерфейса, без SSH.
                </div>
                <button class="yd-btn yd-btn-primary" @click="openDialog('add')">
                  <yd-icon name="plus"></yd-icon> Добавить папку
                </button>
              </div>

              <!-- Папка настроена -->
              <template v-else>
                <!-- Шапка статуса -->
                <div class="yd-card yd-header-card">
                  <status-badge :state="visualStatus" :big="true"></status-badge>
                  <div class="yd-hc-body">
                    <div class="yd-hc-title">{{ statusInfo.label }}</div>

                    <template v-if="visualStatus === 'success'">
                      <div class="yd-muted">
                        Последняя синхронизация:
                        <a class="yd-link" @click="openHistory">{{ state.ts }}</a>
                      </div>
                      <div class="yd-muted">Следующая синхронизация: {{ scheduleLabel === 'По Планировщику задач DSM' ? 'по расписанию Планировщика задач DSM' : 'через ' + config.interval + ' мин (по расписанию пакета)' }}</div>
                    </template>

                    <template v-else-if="visualStatus === 'warning'">
                      <div class="yd-muted">Последняя синхронизация: {{ state.ts }}</div>
                      <div class="yd-note-warn">⚠ Завершено с предупреждением{{ state.result ? ' (' + state.result + ')' : '' }}.
                        <a class="yd-link" @click="openLog">Подробнее в журнале rclone →</a></div>
                    </template>

                    <template v-else-if="visualStatus === 'error'">
                      <div class="yd-muted" v-if="state.ts">Последняя попытка: {{ state.ts }}</div>
                      <div class="yd-note-err">Синхронизация завершилась с ошибкой{{ state.result ? ' (' + state.result + ')' : '' }}.</div>
                      <div style="margin-top:4px"><a class="yd-link" @click="openLog">Подробнее в журнале rclone →</a></div>
                    </template>

                    <template v-else-if="visualStatus === 'syncing'">
                      <div class="yd-muted">Идёт синхронизация с Яндекс Диском…</div>
                      <div class="yd-muted">Это может занять время; журнал — в «Журнале rclone».</div>
                    </template>

                    <template v-else>
                      <div class="yd-muted" v-if="!connected">
                        Яндекс Диск не подключён. Откройте «Настройка» и вставьте токен.
                      </div>
                      <div class="yd-muted" v-else>
                        Готово к первой синхронизации. При первом запуске содержимое папки и Диска
                        объединяется в обе стороны (<code>--resync</code>).
                      </div>
                    </template>

                    <div class="yd-hc-actions">
                      <button class="yd-btn yd-btn-primary" :disabled="!canSync" @click="syncNow">
                        <yd-icon name="sync"></yd-icon>
                        {{ visualStatus === 'error' ? 'Повторить' : 'Синхронизировать сейчас' }}
                      </button>
                      <button class="yd-icon-btn" title="История синхронизации" @click="openHistory">
                        <yd-icon name="clock"></yd-icon>
                      </button>
                      <button class="yd-icon-btn" title="Настройка" @click="openDialog('edit')">
                        <yd-icon name="gear"></yd-icon>
                      </button>
                      <button class="yd-icon-btn danger" disabled
                        title="Удаление папки появится в следующей версии (нет серверной подкоманды)">
                        <yd-icon name="trash"></yd-icon>
                      </button>
                    </div>
                    <div class="yd-note-err" v-if="syncError" style="margin-top:8px">{{ syncError }}</div>
                    <div class="yd-ok-hint" v-if="syncMsg" style="margin-top:8px">✓ {{ syncMsg }}</div>
                  </div>
                </div>

                <!-- Нижние карточки -->
                <div class="yd-detail-bottom">
                  <div class="yd-card">
                    <div class="yd-card-title">Папка</div>
                    <div class="yd-kv"><span class="k">Локальная папка</span><span class="v">{{ config.dir }}</span></div>
                    <div class="yd-kv"><span class="k">Владелец</span><span class="v">{{ folderOwner || '—' }}</span></div>
                    <div class="yd-kv">
                      <span class="k">Подключение к Яндекс Диску</span>
                      <span class="v">
                        <span v-if="connected" class="yd-ok">Подключено ✓</span>
                        <span v-else class="yd-bad">Не подключено</span>
                      </span>
                    </div>
                  </div>
                  <div class="yd-card">
                    <div class="yd-card-title">Настройки синхронизации</div>
                    <div class="yd-kv"><span class="k">Удалённый ресурс</span><span class="v">{{ config.remote }}</span></div>
                    <div class="yd-kv"><span class="k">Чистка thumbs</span><span class="v">{{ config.clean_thumbs === '1' ? 'Вкл.' : 'Выкл.' }}</span></div>
                    <div class="yd-kv"><span class="k">Расписание</span><span class="v">{{ scheduleLabel }}</span></div>
                    <div class="yd-kv"><span class="k">Последний результат</span><span class="v">{{ lastResultLine }}</span></div>
                    <div class="yd-card-foot">
                      <button class="yd-btn yd-btn-secondary" @click="openDialog('edit')">Настройка задачи</button>
                    </div>
                  </div>
                </div>
              </template>
            </div>

            <!-- ───── Модалка: диалог добавления/редактирования ───── -->
            <div v-if="modal === 'dialog'" class="yd-overlay" @click.self="closeModal">
              <div class="yd-modal">
                <div class="yd-modal-head">
                  <span>{{ dialogMode === 'edit' ? 'Настройка папки' : 'Добавить папку' }}</span>
                  <button class="x" @click="closeModal">✕</button>
                </div>
                <div class="yd-modal-body">
                  <div class="yd-form-err" v-if="formError">{{ formError }}</div>

                  <!-- Локальная папка -->
                  <div class="yd-frow">
                    <label>Локальная папка</label>
                    <div class="yd-inline">
                      <input type="text" v-model="form.dir" placeholder="/volume1/…"
                        @input="scheduleCheck" @blur="checkFolder">
                    </div>
                    <div class="yd-field-err" v-if="fieldErr.dir">{{ fieldErr.dir }}</div>
                    <div class="yd-hint" v-if="folderCheck.checking">Проверка папки…</div>
                    <div class="yd-hint yd-ok-hint" v-else-if="folderCheck.checked && folderCheck.exists && folderCheck.writable">
                      ✓ Папка доступна для записи пользователю sc-yandexdisk{{ folderCheck.owner ? ' (владелец: ' + folderCheck.owner + ')' : '' }}
                    </div>
                    <div class="yd-hint yd-bad-hint" v-else-if="folderCheck.checked && folderCheck.exists && !folderCheck.writable">
                      ✗ Нет прав на запись. Дайте пользователю sc-yandexdisk права RW на общую папку в «Панель управления → Общая папка» DSM.
                    </div>
                    <div class="yd-hint" v-else-if="folderCheck.checked && !folderCheck.exists">
                      Папка пока не существует — будет создана при первой синхронизации.
                    </div>
                    <div class="yd-hint" v-else>
                      Абсолютный путь; папка должна быть доступна для записи пользователю <code>sc-yandexdisk</code>.
                    </div>
                  </div>

                  <!-- Удалённый ресурс -->
                  <div class="yd-frow">
                    <label>Удалённый ресурс</label>
                    <input type="text" v-model="form.remote">
                    <div class="yd-field-err" v-if="fieldErr.remote">{{ fieldErr.remote }}</div>
                    <div class="yd-hint">
                      Имя ресурса <code>yandexdisk</code> фиксировано. Можно указать подпапку:
                      <code>yandexdisk:/Backup</code>.
                    </div>
                  </div>

                  <!-- Чистка thumbs -->
                  <div class="yd-frow yd-switch-row">
                    <div>
                      <label style="margin:0">Чистка thumbs</label>
                      <div class="yd-hint" style="margin-top:2px">Удалять эскизы (@eaDir / thumbs) перед синхронизацией</div>
                    </div>
                    <label class="yd-switch">
                      <input type="checkbox" v-model="form.cleanThumbs"><span class="yd-slider"></span>
                    </label>
                  </div>

                  <!-- Подключение к Яндекс Диску (Tier 1) -->
                  <div class="yd-section-title">Подключение к Яндекс Диску</div>
                  <div class="yd-connected-box" v-if="dialogMode === 'edit' && connected && !form.showToken">
                    Подключено ✓ &nbsp;
                    <a class="yd-link" @click="form.showToken = true">Заменить токен</a>
                  </div>
                  <div v-if="form.showToken">
                    <div class="yd-hint">
                      На компьютере с браузером выполните <code>rclone authorize "yandex"</code>
                      и вставьте сюда строку вида <code>{ … }</code>.
                    </div>
                    <textarea rows="3" v-model="form.token"
                      placeholder='{"access_token":"…","token_type":"bearer","expiry":"…"}'></textarea>
                    <div class="yd-field-err" v-if="fieldErr.token">{{ fieldErr.token }}</div>
                    <div class="yd-inline-between">
                      <button class="yd-btn yd-btn-secondary" :disabled="tokenSaving" @click="connectToken">
                        {{ tokenSaving ? 'Подключение…' : 'Подключить' }}
                      </button>
                      <button class="yd-btn yd-btn-ghost" disabled
                        title="Вход через Яндекс прямо из UI требует одобрения (вне MVP)">
                        Войти через Яндекс <span class="yd-pill">вне MVP</span>
                      </button>
                    </div>
                  </div>

                  <!-- Расписание (Опция A) -->
                  <div class="yd-section-title">Расписание</div>
                  <label class="yd-radio"><input type="radio" name="yd-sched" checked disabled>
                    Вручную / по Планировщику задач DSM</label>
                  <div class="yd-sched-hint">
                    Рекомендуется. Создайте задачу в «Планировщик задач» DSM (пользователь root) с командой:<br>
                    <code>{{ syncCmd }}</code>
                    <a class="yd-link" style="margin-left:6px" @click="copySyncCmd">Копировать</a>
                  </div>
                  <label class="yd-radio disabled"><input type="radio" name="yd-sched" disabled>
                    Каждые <input type="number" class="yd-num" value="60" min="5" disabled> минут
                    <span class="yd-pill">вне MVP</span></label>
                </div>
                <div class="yd-modal-foot">
                  <button class="yd-btn yd-btn-secondary" @click="closeModal">Отмена</button>
                  <button class="yd-btn yd-btn-primary" :disabled="saving" @click="save">
                    {{ saving ? 'Сохранение…' : 'Сохранить' }}
                  </button>
                </div>
              </div>
            </div>

            <!-- ───── Модалка: журнал rclone ───── -->
            <div v-if="modal === 'log'" class="yd-overlay" @click.self="closeModal">
              <div class="yd-modal wide">
                <div class="yd-modal-head">
                  <span>Журнал rclone — последняя синхронизация</span>
                  <button class="x" @click="closeModal">✕</button>
                </div>
                <div class="yd-modal-body"><pre class="yd-log">{{ logText }}</pre></div>
              </div>
            </div>

            <!-- ───── Модалка: история синхронизации ───── -->
            <div v-if="modal === 'history'" class="yd-overlay" @click.self="closeModal">
              <div class="yd-modal">
                <div class="yd-modal-head">
                  <span>История синхронизации</span>
                  <button class="x" @click="closeModal">✕</button>
                </div>
                <div class="yd-modal-body"><pre class="yd-log">{{ historyText }}</pre></div>
                <div class="yd-modal-foot">
                  <button class="yd-btn yd-btn-secondary" @click="clearHistory">Очистить</button>
                  <button class="yd-btn yd-btn-primary" @click="closeModal">Закрыть</button>
                </div>
              </div>
            </div>

          </div>
        </v-app-window>
      </v-app-instance>
    `,
  });

  SYNO.namespace("SYNOCOMMUNITY.YandexDisk");
  SYNOCOMMUNITY.YandexDisk.AppInstance = VueRef.extend({
    components: { App },
    template: "<App/>",
  });
})();
