---
name: Баг
about: Что-то работает не так
title: ''
labels: bug
---

## Что произошло

<!-- Коротко: что делали, что ожидали, что получилось -->

## Роутер и версии

```
модель:
OpenWrt (. /etc/openwrt_release):
Podkop (podkop show_version):
sing-box (sing-box version):
```

## Подписка

- формат ответа: обычный список `vless://` / base64 / другое
- сколько серверов в подписке:
- провайдер (если не секрет):

## Вывод команд

```
podkop-sub-update.sh --check
podkop check_dns_available
logread | grep podkop-sub | tail -20
```

<!-- URL подписки и UUID не прикладывайте — достаточно формата и количества -->
