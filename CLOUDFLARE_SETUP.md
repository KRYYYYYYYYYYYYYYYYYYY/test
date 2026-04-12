# Cloudflare Integration Guide

## Зачем нужен Cloudflare?

ТСПУ блокирует прямые подключения к VPS по IP-адресу.  
Cloudflare выступает «фасадом»: клиент подключается к IP Cloudflare (не блокируется),  
а Cloudflare проксирует трафик на ваш реальный сервер.

```
Клиент → Cloudflare CDN (белый IP) → Ваш VPS (скрытый IP)
```

---

## Вариант 1: Cloudflare Workers (рекомендуется)

**Требуется:** аккаунт Cloudflare (бесплатный).  
**Не требуется:** покупка домена (Worker получает субдомен `*.workers.dev`).

### Шаги:

1. Зайдите на https://dash.cloudflare.com → **Workers & Pages** → **Create**
2. Вставьте содержимое файла `cf-worker-proxy.js`
3. В настройках Worker: **Settings** → **Variables** → добавьте:
   - `BACKEND_HOST` = `ваш-домен-сервера.com`
4. Worker получит URL вида: `https://your-worker.username.workers.dev`

### Настройка клиента Xray:

В `config.json` замените адрес сервера:

```json
{
  "address": "your-worker.username.workers.dev",
  "port": 443
}
```

И в `tlsSettings`:

```json
{
  "serverName": "your-worker.username.workers.dev"
}
```

**Важно:** при использовании Worker вместо прямого подключения,  
`dialerProxy: "fragment-proxy"` можно отключить — трафик уже идёт через CDN.

---

## Вариант 2: Cloudflare CDN (с доменом)

**Требуется:** домен (от $1/год: `.xyz`, `.online`, `.site`).

### Шаги:

1. Купите домен (например, на Namecheap, Porkbun, или Cloudflare Registrar)
2. Добавьте домен в Cloudflare
3. Создайте DNS A-запись:
   - Name: `proxy` (или что угодно)
   - Content: `87.242.119.137` (IP вашего VPS)
   - Proxy: **включён** (оранжевое облако ☁️)
4. В настройках SSL/TLS: **Full (strict)**

### Настройка клиента Xray:

```json
{
  "address": "proxy.yourdomain.xyz",
  "port": 443,
  "tlsSettings": {
    "serverName": "proxy.yourdomain.xyz"
  }
}
```

---

## Вариант 3: Cloudflare Tunnel (Zero Trust)

**Требуется:** аккаунт Cloudflare (бесплатный).  
**Не требуется:** покупка домена (туннель получает субдомен).  
**Преимущество:** VPS не открывает никакие порты наружу.

### Шаги на VPS:

1. Установите `cloudflared`:
```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
```

2. Авторизуйтесь:
```bash
cloudflared tunnel login
```

3. Создайте туннель:
```bash
cloudflared tunnel create xray-tunnel
```

4. Настройте конфиг `~/.cloudflared/config.yml`:
```yaml
tunnel: <TUNNEL_ID>
credentials-file: /root/.cloudflared/<TUNNEL_ID>.json

ingress:
  - hostname: xray.yourdomain.com
    service: https://localhost:443
    originRequest:
      noTLSVerify: true
  - service: http_status:404
```

5. Запустите:
```bash
cloudflared tunnel route dns xray-tunnel xray.yourdomain.com
cloudflared tunnel run xray-tunnel
```

### Совместимость с Xray:

Cloudflare Tunnel **полностью совместим** с нашей конфигурацией:

| Компонент | Совместимость | Примечание |
|-----------|:---:|------------|
| VLESS + xHTTP | ✅ | xHTTP работает поверх HTTP — идеально для Tunnel |
| TLS | ✅ | Tunnel терминирует TLS и переподключается к localhost |
| Фрагментация | ⚠️ | Не нужна — Cloudflare сам управляет TCP |
| ECH routing | ✅ | Работает независимо от туннеля |
| UDP/QUIC | ❌ | Tunnel проксирует только HTTP(S) трафик |

**Ограничение UDP:** Cloudflare Tunnel не проксирует UDP.  
Мессенджеры и VoIP будут работать, но через TCP-fallback (медленнее).  
Для полной UDP-поддержки используйте прямое подключение или WARP.

### Systemd-сервис:

```bash
cloudflared service install
systemctl enable cloudflared
systemctl start cloudflared
```

---

## Рекомендация по SNI

Если используете **прямое подключение** (без Cloudflare), смените SNI на более «тяжёлый» домен:

| SNI | Почему |
|-----|--------|
| `google.com` | Массовый трафик, TLS 1.3, сложно заблокировать |
| `cdn.jsdelivr.net` | Популярный CDN, используется миллионами сайтов |
| `www.microsoft.com` | Системный трафик Windows |
| `dl.google.com` | Обновления Chrome/Android |

В `config.json` — `tlsSettings.serverName` (только для Reality, не для xHTTP+TLS).

---

## Приоритет стратегий

1. **Cloudflare Worker** — самый простой, бесплатный, эффективный
2. **Cloudflare CDN** — если есть домен, даёт полный контроль
3. **Cloudflare Tunnel** — максимальная защита, но нет UDP
4. **Прямое подключение + SNI** — если Cloudflare недоступен
