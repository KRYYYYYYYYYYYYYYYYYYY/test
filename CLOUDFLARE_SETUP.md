# Cloudflare Integration Guide

## Зачем нужен Cloudflare?

ТСПУ блокирует прямые подключения к VPS по IP-адресу.  
Cloudflare выступает «фасадом»: клиент подключается к IP Cloudflare (не блокируется),  
а Cloudflare проксирует трафик на ваш реальный сервер.

```
Клиент → Cloudflare CDN (белый IP) → Ваш VPS (скрытый IP)
```

---

## Reality vs xHTTP+Cloudflare — что выбрать?

> **Важно:** Reality и Cloudflare — это **разные** стратегии обхода.  
> Их можно использовать **одновременно** (два конфига), переключаясь по ситуации.

| | Reality (прямое) | xHTTP через Cloudflare |
|---|---|---|
| **Нужен домен?** | Нет | Нет (`*.workers.dev` бесплатно) |
| **Нужны деньги?** | Нет | Нет |
| **Как маскируется?** | Имитирует TLS к чужому сайту (SNI) | Реальный HTTPS к Cloudflare |
| **ТСПУ видит** | IP вашего VPS | IP Cloudflare (белый) |
| **Скорость** | Максимальная | Чуть ниже (через CDN) |
| **UDP/QUIC** | Полная поддержка | Только TCP (UDP через fallback) |
| **Когда работает** | Wi-Fi, стабильный инет | Мобильный инет, когда Reality заблокирован |

**Вывод:** Reality быстрее и поддерживает UDP, но ТСПУ может заблокировать IP сервера.  
Cloudflare Workers — надёжный fallback, который почти невозможно заблокировать.

**Стратегия «два конфига»:**
- Конфиг 1: Reality (прямое подключение) — для Wi-Fi и когда работает
- Конфиг 2: xHTTP через Cloudflare Worker — когда мобильный ТСПУ блокирует Reality

---

## Бесплатные варианты (без покупки домена)

### DuckDNS, deSEC — заблокированы в РФ?

Да, эти сервисы могут быть заблокированы. **Но они вам не нужны:**

- **Для Reality** — домен не нужен вообще. Reality использует чужой SNI (google.com и т.д.).
- **Для Cloudflare Workers** — домен не нужен. Worker получает бесплатный субдомен `*.workers.dev`.
- **Для Cloudflare Tunnel** — нужен домен в Cloudflare, но можно использовать дешёвый (от $1/год).

---

## Вариант 1: Cloudflare Workers (рекомендуется, БЕСПЛАТНО)

**Стоимость:** $0  
**Требуется:** аккаунт Cloudflare (бесплатный).  
**Не требуется:** покупка домена (Worker получает субдомен `*.workers.dev`).  
**Лимит:** 100,000 запросов/день (бесплатный тариф) — хватает для личного VPN.

### Шаги:

1. Зарегистрируйтесь на https://dash.cloudflare.com (бесплатно)
2. Перейдите в **Workers & Pages** → **Create**
3. Дайте Worker имя (например, `my-api`)
4. Вставьте содержимое файла `cf-worker-proxy.js`
5. В настройках Worker: **Settings** → **Variables** → добавьте:
   - `BACKEND_HOST` = IP или домен вашего VPS (например, `87.242.119.137`)
6. Worker получит URL вида: `https://my-api.username.workers.dev`

### Настройка клиента Xray:

В `config.json` замените адрес сервера и `serverName`:

```json
{
  "vnext": [
    {
      "address": "my-api.username.workers.dev",
      "port": 443,
      "users": [
        {
          "id": "<YOUR_UUID>",
          "encryption": "none",
          "flow": ""
        }
      ]
    }
  ]
}
```

И в `tlsSettings`:

```json
{
  "serverName": "my-api.username.workers.dev",
  "fingerprint": "chrome",
  "alpn": ["h2"],
  "allowInsecure": false
}
```

**Важно:**
- `security` остаётся `"tls"` (не Reality — Cloudflare терминирует TLS сам)
- `dialerProxy: "fragment-proxy"` можно убрать — трафик уже идёт через CDN
- Транспорт `xhttp` остаётся без изменений

---

## Вариант 2: Cloudflare CDN (с доменом)

**Стоимость:** от $1/год за домен  
**Требуется:** домен (дешёвые: `.xyz`, `.online`, `.site`, `.click`).

### Шаги:

1. Купите домен (Porkbun, Cloudflare Registrar, Namecheap)
2. Добавьте домен в Cloudflare
3. Создайте DNS A-запись:
   - Name: `proxy` (или что угодно)
   - Content: IP вашего VPS
   - Proxy: **включён** (оранжевое облако)
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

**Стоимость:** $0 (но нужен домен в Cloudflare для hostname)  
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

| Компонент | Совместимость | Примечание |
|-----------|:---:|------------|
| VLESS + xHTTP | Да | xHTTP работает поверх HTTP — идеально для Tunnel |
| TLS | Да | Tunnel терминирует TLS и переподключается к localhost |
| Фрагментация | Не нужна | Cloudflare сам управляет TCP |
| ECH routing | Да | Работает независимо от туннеля |
| UDP/QUIC | Нет | Tunnel проксирует только HTTP(S) трафик |

**Ограничение UDP:** Cloudflare Tunnel не проксирует UDP.  
Мессенджеры и VoIP будут работать, но через TCP-fallback (медленнее).

### Systemd-сервис:

```bash
cloudflared service install
systemctl enable cloudflared
systemctl start cloudflared
```

---

## Рекомендация по SNI (для Reality)

Если используете **прямое подключение с Reality** (без Cloudflare), смените SNI:

| SNI | Почему |
|-----|--------|
| `google.com` | Массовый трафик, TLS 1.3, сложно заблокировать |
| `cdn.jsdelivr.net` | Популярный CDN, используется миллионами сайтов |
| `www.microsoft.com` | Системный трафик Windows |
| `dl.google.com` | Обновления Chrome/Android |

В `config.json` → `tlsSettings.serverName` (только для Reality-конфига).

**Важно:** SNI для Reality — это НЕ ваш домен. Это домен, за который ваш сервер «притворяется».

---

## Приоритет стратегий (от лучшего к запасному)

| # | Стратегия | Стоимость | Лучший случай |
|---|-----------|-----------|---------------|
| 1 | **Cloudflare Worker** | Бесплатно | Мобильный инет, ТСПУ блокирует IP |
| 2 | **Reality + хороший SNI** | Бесплатно | Wi-Fi, стабильный канал |
| 3 | **Cloudflare CDN** | от $1/год | Полный контроль, свой домен |
| 4 | **Cloudflare Tunnel** | от $1/год | Максимальная скрытность, но нет UDP |

---

## Быстрый старт (для студента без денег)

1. **На VPS** — настрой серверный шум одной командой:
```bash
sudo bash -c "$(curl -sSfL https://raw.githubusercontent.com/KRYYYYYYYYYYYYYYYYYYY/test/main/deploy-server.sh)"
```

2. **Cloudflare Worker** — бесплатно, 5 минут:
   - Регистрация на cloudflare.com
   - Workers & Pages → Create → вставить `cf-worker-proxy.js`
   - Добавить переменную `BACKEND_HOST` = IP сервера
   - Готово! URL: `https://my-api.username.workers.dev`

3. **Клиент** — укажи Worker URL в `config.json` вместо IP сервера

**Итого: $0, два аккаунта (Cloudflare + VPS), 15 минут настройки.**
