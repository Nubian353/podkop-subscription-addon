#!/bin/sh
# podkop-sub-update.sh — обновляет urltest-ссылки Podkop из подписки.
# Настройки берутся из UCI: /etc/config/podkop_sub (секция settings).
#
#   /usr/bin/podkop-sub-update.sh            обычный запуск
#   /usr/bin/podkop-sub-update.sh --check    только проверить подписку, ничего не менять
#   SUB_URL=... /usr/bin/podkop-sub-update.sh --check   проверить конкретный URL
#
# Отбор двухступенчатый: ICMP-пинг только упорядочивает кандидатов, а в итоговый
# список попадают лишь те, у кого реально поднялся прокси (проверка через Clash API
# Podkop). Узлы, добавленные вручную (не из подписки), сохраняются.

TAG="podkop-sub"
STATUS_FILE="/tmp/podkop-sub.status"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

say() {
    logger -t "$TAG" "$1"
    [ "$CHECK" = "1" ] || printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" > "$STATUS_FILE"
    printf '%s\n' "$1"
}

TOP_N=$(uci -q get podkop_sub.settings.top_n)
MIN_COUNT=$(uci -q get podkop_sub.settings.min_count)
ENABLED=$(uci -q get podkop_sub.settings.enabled)
SUB_URL="${SUB_URL:-$(uci -q get podkop_sub.settings.url)}"

: "${TOP_N:=6}"
: "${MIN_COUNT:=5}"

# сколько кандидатов проверять реальным прокси-хендшейком за один прогон
LIMIT=40
# сколько ждать, пока Podkop поднимет outbounds и urltest их прощупает
PROBE_WAIT=45

[ "$ENABLED" = "0" ] && { say "автообновление выключено в настройках"; exit 0; }
[ -n "$SUB_URL" ] || { say "ошибка: URL подписки не задан"; exit 1; }

TMP=$(mktemp -d /tmp/podkop-sub.XXXXXX) || { say "ошибка: нет места в /tmp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

host_of() { printf '%s' "$1" | sed -E 's#^[a-z0-9]+://[^@]*@(\[[^]]+\]|[^:/?]+).*#\1#'; }
rtt_of() { ping -c1 -W1 "$1" 2>/dev/null | grep -oE 'time=[0-9.]+' | head -1 | cut -d= -f2; }

extract() { # extract <файл> — печатает ссылки
    tr ' ' '\n' < "$1" 2>/dev/null \
        | grep -oE '(vless|hysteria2|vmess|trojan)://[^"<>[:space:]]+' \
        | grep -v '@localhost'
}

curl -fsS -m 40 -A "Podkop-sub-updater/1.0" -o "$TMP/sub.txt" "$SUB_URL" 2>/dev/null || {
    say "ошибка: подписка не скачалась (проверьте URL)"; exit 1; }

# зашифрованная ссылка HAPP — это не подписка, а контейнер с ключом внутри приложения
if head -c 8 "$TMP/sub.txt" 2>/dev/null | grep -qi '^happ://'; then
    say "ошибка: это зашифрованная ссылка HAPP (happ://crypt). Нужна обычная ссылка-подписка — запросите её у провайдера"
    exit 1
fi

extract "$TMP/sub.txt" > "$TMP/links"

# тело может быть в base64 (стандарт v2ray-подписок)
if [ ! -s "$TMP/links" ]; then
    if base64 -d < "$TMP/sub.txt" > "$TMP/sub.dec" 2>/dev/null && [ -s "$TMP/sub.dec" ]; then
        extract "$TMP/sub.dec" > "$TMP/links"
        [ -s "$TMP/links" ] && say "подписка была в base64 — раскодировал"
    fi
fi

[ -s "$TMP/links" ] || {
    say "ошибка: в ответе нет ссылок (другой формат, пустая подписка или зашифрованное содержимое)"
    exit 1
}

N=$(wc -l < "$TMP/links")
[ "${N:-0}" -ge "$MIN_COUNT" ] || { say "ошибка: в подписке мало ссылок ($N < $MIN_COUNT), список не меняю"; exit 1; }

: > "$TMP/uniq"; : > "$TMP/seen"
while IFS= read -r L; do
    H=$(host_of "$L"); [ -n "$H" ] || continue
    grep -qxF "$H" "$TMP/seen" && continue
    printf '%s\n' "$H" >> "$TMP/seen"
    printf '%s\n' "$L" >> "$TMP/uniq"
done < "$TMP/links"

# ICMP-задержка — только для порядка кандидатов, не критерий живости
: > "$TMP/rank"
while IFS= read -r L; do
    H=$(host_of "$L")
    R=$(rtt_of "$H"); [ -n "$R" ] || continue
    printf '%s %s\n' "$R" "$L" >> "$TMP/rank"
done < "$TMP/uniq"

[ -s "$TMP/rank" ] || { say "ошибка: ни один сервер из подписки не отвечает"; exit 1; }

sort -n "$TMP/rank" > "$TMP/rank.sorted" && mv "$TMP/rank.sorted" "$TMP/rank"

if [ "$CHECK" = "1" ]; then
    say "проверка: ссылок $N, серверов $(wc -l < "$TMP/uniq"), отвечает по ICMP $(wc -l < "$TMP/rank"), лучший RTT $(head -1 "$TMP/rank" | cut -d' ' -f1) мс"
    exit 0
fi

CUR=$(uci -q get podkop.main.urltest_proxy_links)

apply_list() { # apply_list <файл со ссылками>
    uci -q delete podkop.main.urltest_proxy_links
    while IFS= read -r L; do
        [ -n "$L" ] && uci add_list podkop.main.urltest_proxy_links="$L"
    done < "$1"
    uci set podkop.main.proxy_config_type="urltest"
    uci commit podkop || return 1
    /etc/init.d/podkop restart >/dev/null 2>&1
}

# 1) ручные узлы (не из подписки) — сохраняем как есть
: > "$TMP/manual"
for L in $CUR; do
    H=$(host_of "$L"); [ -n "$H" ] || continue
    grep -qxF "$H" "$TMP/seen" && continue
    printf '%s\n' "$L" >> "$TMP/manual"
done

# 2) кандидаты — до LIMIT лучших по ICMP
cut -d' ' -f2- "$TMP/rank" | head -n "$LIMIT" > "$TMP/cand"
[ -s "$TMP/cand" ] || { say "ошибка: пустой список кандидатов"; exit 1; }

# 3) применить кандидатов и дождаться, пока urltest их прощупает
apply_list "$TMP/cand" || { say "ошибка: не удалось применить конфиг Podkop"; exit 1; }
sleep "$PROBE_WAIT"

# 4) проверить каждого реальным прокси-хендшейком через Clash API
: > "$TMP/alive"
i=0
while IFS= read -r L; do
    i=$((i + 1))
    D=$(podkop clash_api get_proxy_latency "main-${i}-out" 2>/dev/null | grep -oE '"delay": *[0-9]+' | grep -oE '[0-9]+')
    [ -n "$D" ] || continue
    printf '%s %s\n' "$D" "$L" >> "$TMP/alive"
done < "$TMP/cand"

A=$(wc -l < "$TMP/alive")
if [ "${A:-0}" -lt 1 ]; then
    # ни один не поднялся — это состояние хуже текущего, возвращаем прежний список
    say "проверка прокси: ни один узел не поднялся, возвращаю прежний список"
    printf '%s\n' $CUR > "$TMP/prev"
    apply_list "$TMP/prev"
    exit 1
fi

# 5) итог: TOP_N самых быстрых по реальному delay + ручные узлы
sort -n "$TMP/alive" | cut -d' ' -f2- | head -n "$TOP_N" > "$TMP/final"
[ -s "$TMP/manual" ] && cat "$TMP/manual" >> "$TMP/final"

F=$(wc -l < "$TMP/final")
OLD=$(printf '%s\n' $CUR | sed '/^$/d' | sort)
NEW=$(sed '/^$/d' "$TMP/final" | sort)

if [ "$OLD" = "$NEW" ]; then
    say "без изменений: $F узлов, живых по прокси $A из $(wc -l < "$TMP/cand")"
    exit 0
fi

apply_list "$TMP/final" || { say "ошибка: не удалось сохранить конфиг Podkop"; exit 1; }
say "обновлено: $F узлов (живых по прокси $A из $(wc -l < "$TMP/cand"))"
