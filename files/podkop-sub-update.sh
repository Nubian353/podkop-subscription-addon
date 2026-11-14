#!/bin/sh
# podkop-sub-update.sh — обновляет urltest-ссылки Podkop из подписки.
# Настройки берутся из UCI: /etc/config/podkop_sub (секция settings).
# Запуск вручную: /usr/bin/podkop-sub-update.sh

TAG="podkop-sub"
STATUS_FILE="/tmp/podkop-sub.status"

say() {
    logger -t "$TAG" "$1"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" > "$STATUS_FILE"
    printf '%s\n' "$1"
}

SUB_URL=$(uci -q get podkop_sub.settings.url)
TOP_N=$(uci -q get podkop_sub.settings.top_n)
MIN_COUNT=$(uci -q get podkop_sub.settings.min_count)
ENABLED=$(uci -q get podkop_sub.settings.enabled)

# совместимость со старым конфигом, если UCI ещё не заполнен
if [ -z "$SUB_URL" ] && [ -f /etc/podkop-sub.conf ]; then
    . /etc/podkop-sub.conf
    SUB_URL="${SUB_URL:-}"
fi

: "${TOP_N:=6}"
: "${MIN_COUNT:=5}"

[ "$ENABLED" = "0" ] && { say "автообновление выключено в настройках"; exit 0; }
[ -n "$SUB_URL" ] || { say "ошибка: URL подписки не задан"; exit 1; }

TMP=$(mktemp -d /tmp/podkop-sub.XXXXXX) || { say "ошибка: нет места в /tmp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

host_of() { printf '%s' "$1" | sed -E 's#^vless://[^@]*@(\[[^]]+\]|[^:/?]+).*#\1#'; }
rtt_of() { ping -c1 -W1 "$1" 2>/dev/null | grep -oE 'time=[0-9.]+' | head -1 | cut -d= -f2; }

curl -fsS -m 40 -A "Podkop-sub-updater/1.0" -o "$TMP/sub.txt" "$SUB_URL" 2>/dev/null || {
    say "ошибка: подписка не скачалась (проверьте URL)"; exit 1; }

tr ' ' '\n' < "$TMP/sub.txt" \
    | grep -oE 'vless://[^"<>[:space:]]+' \
    | grep -v '@localhost' > "$TMP/links"

N=$(wc -l < "$TMP/links")
[ "${N:-0}" -ge "$MIN_COUNT" ] || { say "ошибка: в подписке мало ссылок ($N < $MIN_COUNT), список не меняю"; exit 1; }

: > "$TMP/uniq"; : > "$TMP/seen"
while IFS= read -r L; do
    H=$(host_of "$L"); [ -n "$H" ] || continue
    grep -qxF "$H" "$TMP/seen" && continue
    printf '%s\n' "$H" >> "$TMP/seen"
    printf '%s\n' "$L" >> "$TMP/uniq"
done < "$TMP/links"

: > "$TMP/rank"
while IFS= read -r L; do
    H=$(host_of "$L")
    R=$(rtt_of "$H"); [ -n "$R" ] || continue
    printf '%s %s\n' "$R" "$L" >> "$TMP/rank"
done < "$TMP/uniq"

[ -s "$TMP/rank" ] || { say "ошибка: ни один сервер из подписки не отвечает"; exit 1; }

# 1) оставляем живые текущие узлы — чтобы не дёргать Podkop без нужды
: > "$TMP/chosen"; : > "$TMP/chosen_hosts"
CUR=$(uci -q get podkop.main.urltest_proxy_links)
for L in $CUR; do
    [ "$(wc -l < "$TMP/chosen")" -ge "$TOP_N" ] && break
    H=$(host_of "$L"); [ -n "$H" ] || continue
    grep -qxF "$H" "$TMP/chosen_hosts" && continue
    [ -n "$(rtt_of "$H")" ] || continue
    printf '%s\n' "$L" >> "$TMP/chosen"
    printf '%s\n' "$H" >> "$TMP/chosen_hosts"
done

# 2) добираем лучшими по задержке
while read -r R L; do
    [ "$(wc -l < "$TMP/chosen")" -ge "$TOP_N" ] && break
    H=$(host_of "$L")
    grep -qxF "$H" "$TMP/chosen_hosts" && continue
    printf '%s\n' "$L" >> "$TMP/chosen"
    printf '%s\n' "$H" >> "$TMP/chosen_hosts"
done < "$TMP/rank"

M=$(wc -l < "$TMP/chosen")
[ "${M:-0}" -ge 1 ] || { say "ошибка: пустой список узлов"; exit 1; }

OLD=$(printf '%s\n' $CUR | sed '/^$/d' | sort)
NEW=$(sort "$TMP/chosen")

if [ "$OLD" = "$NEW" ]; then
    say "без изменений: $M узлов, лучший RTT $(head -1 "$TMP/rank" | cut -d' ' -f1) мс"
    exit 0
fi

uci -q delete podkop.main.urltest_proxy_links
while IFS= read -r L; do
    uci add_list podkop.main.urltest_proxy_links="$L"
done < "$TMP/chosen"
uci set podkop.main.proxy_config_type="urltest"
uci commit podkop || { say "ошибка: не удалось сохранить конфиг Podkop"; exit 1; }

/etc/init.d/podkop restart >/dev/null 2>&1
say "обновлено: $M узлов, лучший RTT $(head -1 "$TMP/rank" | cut -d' ' -f1) мс"
