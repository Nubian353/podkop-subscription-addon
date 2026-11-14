#!/bin/sh
# install.sh — установка подписки для Podkop на OpenWrt.
# Использование:
#   curl -fsSL .../install.sh | sh -s -- --url "https://…"
#   ./install.sh --url "https://…" --top 6

set -u

RAW="${REPO_RAW:-https://raw.githubusercontent.com/Nubian353/podkop-sub/main}"

SUB_URL=""
TOP_N="6"
MIN_COUNT="5"
RUN_MODE="ask"

die()  { echo "ОШИБКА: $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }
info() { echo "  · $*"; }

usage() {
    cat <<EOF
Установка подписки для Podkop.

Параметры:
  --url URL    ссылка на подписку
  --top N      сколько серверов держать в Podkop (по умолчанию 6)
  --min N      минимум ссылок в подписке (по умолчанию 5)
  --run        сразу применить список
  --no-run     не применять сразу
  -h, --help   эта справка
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --url) SUB_URL="${2:-}"; shift 2 ;;
        --top) TOP_N="${2:-}"; shift 2 ;;
        --min) MIN_COUNT="${2:-}"; shift 2 ;;
        --run) RUN_MODE="yes"; shift ;;
        --no-run) RUN_MODE="no"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "неизвестный параметр: $1 (см. --help)" ;;
    esac
done

echo "== Проверка системы =="
[ -f /etc/openwrt_release ] || die "это не OpenWrt"
command -v uci >/dev/null 2>&1 || die "нет uci — это точно OpenWrt?"
. /etc/openwrt_release
ok "OpenWrt $DISTRIB_RELEASE ($DISTRIB_ARCH)"

if [ -x /usr/bin/podkop ] || [ -d /usr/share/luci/menu.d ] && [ -f /usr/share/luci/menu.d/luci-app-podkop.json ]; then
    ok "Podkop найден"
else
    echo "  ! Podkop не найден. Установите его: sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)"
    echo "  ! (в ash вместо <( ) используйте: wget -O /tmp/p.sh URL && sh /tmp/p.sh)"
fi

command -v cron >/dev/null 2>&1 || [ -x /etc/init.d/cron ] || info "cron не найден — автообновление по расписанию работать не будет"

# --- источник файлов: локальная копия или репозиторий ---
SELF_DIR=$(dirname "$0" 2>/dev/null || echo ".")
if [ -f "$SELF_DIR/files/podkop-sub-update.sh" ]; then
    SRC="local"
    ok "использую локальные файлы: $SELF_DIR/files"
else
    SRC="remote"
    ok "скачиваю файлы из репозитория"
fi

TMP=$(mktemp -d /tmp/podkop-sub-install.XXXXXX) || die "не удалось создать временный каталог"
trap 'rm -rf "$TMP"' EXIT

fetch() { # fetch <url> <out>
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -m 60 "$1" -o "$2"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        return 1
    fi
}

get_file() { # get_file <относительный путь> <куда>
    if [ "$SRC" = "local" ]; then
        cp "$SELF_DIR/files/$1" "$2" || return 1
    else
        fetch "$RAW/files/$1" "$2" || return 1
    fi
    [ -s "$2" ] || return 1
}

echo "== Установка файлов =="
mkdir -p /www/luci-static/resources/view/podkop-sub

get_file podkop-sub-update.sh "$TMP/update.sh" || die "не удалось получить podkop-sub-update.sh"
get_file view/podkop-sub/settings.js "$TMP/settings.js" || die "не удалось получить settings.js"
get_file luci-app-podkop-sub.json "$TMP/menu.json" || die "не удалось получить menu.json"
get_file luci-app-podkop-sub.acl.json "$TMP/acl.json" || die "не удалось получить acl.json"

put_file() { # put_file <src> <dst> <mode>
    cp "$1" "$2" || return 1
    chmod "$3" "$2" || return 1
}

put_file "$TMP/update.sh"   /usr/bin/podkop-sub-update.sh 755 || die "не удалось установить скрипт"
put_file "$TMP/settings.js" /www/luci-static/resources/view/podkop-sub/settings.js 644 || die "не удалось установить страницу"
put_file "$TMP/menu.json"   /usr/share/luci/menu.d/luci-app-podkop-sub.json 644 || die "не удалось установить меню"
put_file "$TMP/acl.json"    /usr/share/rpcd/acl.d/luci-app-podkop-sub.json 644 || die "не удалось установить ACL"
ok "скрипт, страница LuCI, меню и ACL на месте"

echo "== Настройки =="
if [ -z "$SUB_URL" ]; then
    EXISTING=$(uci -q get podkop_sub.settings.url)
    if [ -n "$EXISTING" ]; then
        ok "URL подписки уже задан — оставляю как есть"
        SUB_URL="$EXISTING"
    elif [ -t 0 ]; then
        printf "  Введите URL подписки: "
        read -r SUB_URL
    fi
fi

if [ -n "$SUB_URL" ]; then
    uci -q delete podkop_sub.settings >/dev/null 2>&1
    uci set podkop_sub.settings=settings
    uci set podkop_sub.settings.url="$SUB_URL"
    uci set podkop_sub.settings.top_n="$TOP_N"
    uci set podkop_sub.settings.min_count="$MIN_COUNT"
    uci set podkop_sub.settings.enabled="1"
    uci commit podkop_sub
    chmod 600 /etc/config/podkop_sub 2>/dev/null
    ok "URL сохранён в /etc/config/podkop_sub (права 600)"
else
    info "URL не задан — впишите его в LuCI: Службы → VPN-подписка"
fi

echo "== Автообновление =="
mkdir -p /etc/crontabs
touch /etc/crontabs/root
if grep -q 'podkop-sub-update' /etc/crontabs/root 2>/dev/null; then
    ok "запись в cron уже есть"
else
    echo '17 */6 * * * /usr/bin/podkop-sub-update.sh' >> /etc/crontabs/root
    ok "добавлено в cron: каждые 6 часов"
fi
/etc/init.d/cron restart >/dev/null 2>&1
/etc/init.d/rpcd restart >/dev/null 2>&1
/etc/init.d/uhttpd reload >/dev/null 2>&1
ok "службы перезапущены"

echo
echo "Готово. Откройте LuCI → Службы → «VPN-подписка»."

if [ -n "$SUB_URL" ]; then
    if [ "$RUN_MODE" = "ask" ] && [ -t 0 ]; then
        printf "Применить список узлов сейчас? [y/N] "
        read -r ANS
        case "${ANS:-}" in y|Y|yes) RUN_MODE="yes" ;; *) RUN_MODE="no" ;; esac
    fi
    if [ "$RUN_MODE" = "yes" ]; then
        echo "== Первый запуск =="
        /usr/bin/podkop-sub-update.sh
    else
        info "запуск отложен: кнопка «Обновить сейчас» в LuCI или cron"
    fi
fi
