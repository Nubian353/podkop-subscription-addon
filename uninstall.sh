#!/bin/sh
# uninstall.sh — удаляет podkop-sub с роутера.
# Настройки самого Podkop не трогаются.

set -u

echo "== Удаление podkop-sub =="

[ -f /etc/openwrt_release ] || { echo "ОШИБКА: это не OpenWrt" >&2; exit 1; }

rm -f /usr/bin/podkop-sub-update.sh
rm -f /usr/share/luci/menu.d/luci-app-podkop-sub.json
rm -f /usr/share/rpcd/acl.d/luci-app-podkop-sub.json
rm -f /www/luci-static/resources/view/podkop-sub/settings.js
rmdir /www/luci-static/resources/view/podkop-sub 2>/dev/null
rm -f /tmp/podkop-sub.status
echo "  ✓ файлы удалены"

if [ -f /etc/crontabs/root ]; then
    grep -v 'podkop-sub-update' /etc/crontabs/root > /tmp/crontab.new 2>/dev/null
    mv /tmp/crontab.new /etc/crontabs/root
    echo "  ✓ запись из cron убрана"
fi
/etc/init.d/cron restart >/dev/null 2>&1

uci -q delete podkop_sub >/dev/null 2>&1
rm -f /etc/config/podkop_sub
echo "  ✓ настройки удалены"

/etc/init.d/rpcd restart >/dev/null 2>&1
/etc/init.d/uhttpd reload >/dev/null 2>&1
echo "  ✓ LuCI перезагружен"

echo
echo "Готово. Podkop и его настройки (DNS, списки, узлы) не тронуты."
