# Mobile Stability Playbook: Advanced Multi-Layer Protection

Продвинутая конфигурация Xray для стабильной работы на мобильных сетях (LTE/5G) с защитой от Middlebox Interference.

Основана на анализе проектов: [autoXRAY](https://github.com/AliRezaAghaworker/autoXRAY), [singbox-ech-list](https://github.com/Akiyamov/singbox-ech-list), [zapret4rocket](https://github.com/topics/zapret).

---

## Архитектура: 4 уровня защиты

```
+------------------------------------------------------------------+
|  Level 4: UDP Stabilization (noise + padding)                    |
|  Level 3: L4 Fragmentation (TLS ClientHello splitting)           |
|  Level 2: ECH Routing (direct for ECH / proxy for non-ECH)      |
|  Level 1: xHTTP Transport (L7 browser imitation)                 |
+------------------------------------------------------------------+
```

---

## Level 1: xHTTP Transport (L7-имитация)

### Что это

Транспорт [XHTTP](https://github.com/XTLS/Xray-core/discussions/4113) инкапсулирует данные в короткие HTTP-транзакции (POST/GET). Трафик мимикрирует под легальные запросы к API, что фундаментально снижает вероятность классификации как "неизвестный туннель" со стороны ISP.

### Ключевые параметры в config.json

```json
"streamSettings": {
  "network": "xhttp",
  "xhttpSettings": {
    "path": "/<SECRET_PATH>",
    "mode": "auto",
    "xPaddingBytes": "100-1000",
    "xmux": {
      "maxConcurrency": "16-32",
      "cMaxReuseTimes": "64-128",
      "hMaxRequestTimes": "600-900",
      "hMaxReusableSecs": "1800-3000"
    },
    "scMaxEachPostBytes": "500000-1000000",
    "scMinPostsIntervalMs": "10-50"
  }
}
```

### Почему это работает

| Параметр | Назначение |
|----------|-----------|
| `mode: "auto"` | Автоматический выбор: stream-up для TLS H2, packet-up для остальных |
| `xPaddingBytes: "100-1000"` | Рандомизация размеров заголовков — устраняет фиксированные паттерны |
| `xmux` | Мультиплексирование с ротацией — периодическая смена H2-соединений |
| `scMaxEachPostBytes` | Ограничение размера POST-запросов, совместимость с CDN/middlebox |
| `scMinPostsIntervalMs` | Рандомизация интервалов между запросами |

### Режимы xHTTP

- **packet-up** (по умолчанию без TLS): разбивает uplink на короткие POST-запросы, максимальная совместимость с CDN
- **stream-up** (TLS H2): полный потоковый uplink с gRPC-имитацией заголовков
- **stream-one** (REALITY): единый POST-запрос с двусторонним streaming

---

## Level 2: ECH-Routing (Encrypted Client Hello)

### Что это

Гибридная маршрутизация на основе [singbox-ech-list](https://github.com/Akiyamov/singbox-ech-list):
- Сайты с поддержкой ECH идут **напрямую** (Freedom) — ТСПУ видит домен Cloudflare вместо реального
- Сайты без ECH идут через **прокси** с полной обфускацией

### Установка ech.dat

```bash
# Скачать актуальную базу ECH-доменов
sudo wget -O /usr/share/xray/ech.dat \
  https://github.com/Akiyamov/singbox-ech-list/releases/latest/download/ech.dat
```

### Автообновление (cron)

```bash
# Обновлять ech.dat каждые 12 часов
echo "0 */12 * * * root wget -qO /usr/share/xray/ech.dat https://github.com/Akiyamov/singbox-ech-list/releases/latest/download/ech.dat && systemctl restart xray" \
  | sudo tee /etc/cron.d/ech-update
```

### Правила маршрутизации

```json
"routing": {
  "rules": [
    {
      "type": "field",
      "domain": ["ext:ech.dat:domains_ech"],
      "outboundTag": "freedom-ech"
    },
    {
      "type": "field",
      "domain": ["ext:ech.dat:domains_noech"],
      "outboundTag": "proxy-xhttp"
    }
  ]
}
```

### ECH outbound (Freedom с ECH)

```json
{
  "tag": "freedom-ech",
  "protocol": "freedom",
  "streamSettings": {
    "security": "tls",
    "tlsSettings": {
      "fingerprint": "chrome",
      "echConfigList": "cloudflare-ech.crypto.cloudflare.com+udp://1.1.1.1"
    }
  }
}
```

Xray автоматически получает ECH-конфигурацию через DNS (HTTPS RR) и устанавливает зашифрованное соединение, скрывая SNI от DPI.

**Требование**: использовать DoH/DoT DNS (не из РФ), так как российские DNS могут вырезать ECH-записи.

---

## Level 3: L4 Fragmentation (TLS ClientHello Splitting)

### Что это

Микро-фрагментация первого TLS-кадра (ClientHello). Пакет разрезается на части по 1-3 байта с задержкой 1-5 мс между фрагментами. Это "ослепляет" DPI-оборудование Middlebox-узлов.

### Конфигурация (Freedom outbound)

```json
{
  "tag": "fragment-proxy",
  "protocol": "freedom",
  "settings": {
    "fragment": {
      "packets": "tlshello",
      "length": "1-3",
      "interval": "1-5"
    }
  },
  "streamSettings": {
    "sockopt": {
      "tcpNoDelay": true
    }
  }
}
```

### Параметры

| Параметр | Значение | Описание |
|----------|----------|----------|
| `packets` | `"tlshello"` | Фрагментация только TLS ClientHello (не весь TCP) |
| `length` | `"1-3"` | Размер каждого фрагмента: 1-3 байта (агрессивная фрагментация) |
| `interval` | `"1-5"` | Задержка между фрагментами: 1-5 мс |
| `tcpNoDelay` | `true` | Отключить алгоритм Nagle для немедленной отправки фрагментов |

### Как использовать

Fragment outbound используется как **dialer-proxy** через цепочку outbound:

```json
{
  "tag": "proxy-xhttp",
  "protocol": "vless",
  "streamSettings": {
    "sockopt": {
      "dialerProxy": "fragment-proxy"
    }
  }
}
```

Либо как самостоятельный outbound для прямого доступа к заблокированным сайтам без прокси.

### Когда использовать

- ISP блокирует по SNI в ClientHello
- Наблюдаются DPI False Positives на TLS-рукопожатии
- Соединения обрываются именно в момент handshake

### Когда НЕ использовать

- Если ISP выполняет полную TCP-reassembly (тогда фрагментация бесполезна)
- При работе через CDN (CDN сам терминирует TLS)

---

## Level 4: UDP Stabilization (Noise + Padding)

### Что это

Два механизма:
1. **UDP Noise** — отправка "шумовых" пакетов перед реальным UDP-соединением
2. **xHTTP Padding** — рандомизация размеров HTTP-заголовков

### UDP Noise (Freedom outbound)

```json
{
  "tag": "noise-udp",
  "protocol": "freedom",
  "settings": {
    "noises": [
      {
        "type": "rand",
        "packet": "10-50",
        "delay": "1-5"
      },
      {
        "type": "rand",
        "packet": "50-150",
        "delay": "5-10"
      },
      {
        "type": "base64",
        "packet": "7nQBAAABAAAAAAAABnQtcmluZwZtc2VkZ2UDbmV0AAABAAE=",
        "delay": "10-16"
      }
    ]
  }
}
```

### Параметры Noise

| Тип | Назначение |
|-----|-----------|
| `rand` 10-50 байт | Короткий рандомный пакет — маскировка начала сессии |
| `rand` 50-150 байт | Средний рандомный пакет — выравнивание статистического паттерна |
| `base64` DNS-like | Имитация DNS-запроса — дополнительная мимикрия |

### Routing для UDP-noise

```json
{
  "type": "field",
  "network": "udp",
  "port": "1026-65535",
  "outboundTag": "noise-udp"
}
```

Порт 53 (DNS) исключен автоматически — noise может сломать DNS-резолвинг.
Порты 1-1025 исключены для совместимости со стандартными сервисами.

### xHTTP Padding

Параметр `xPaddingBytes: "100-1000"` автоматически добавляет случайные данные в HTTP-заголовки каждого запроса/ответа. Это:
- Устраняет фиксированные паттерны размеров пакетов
- Лишает DPI возможности статистической деанонимизации протокола
- Совместимо с CDN (Cloudflare, CDNVideo и др.)

---

## Быстрый старт

### 1. Подготовка сервера

Убедитесь, что на сервере установлен Xray >= 25.1.1 с поддержкой xHTTP.

### 2. Установка ech.dat на клиенте

```bash
sudo mkdir -p /usr/share/xray
sudo wget -O /usr/share/xray/ech.dat \
  https://github.com/Akiyamov/singbox-ech-list/releases/latest/download/ech.dat
```

### 3. Настройка config.json

Откройте `config.json` из этого репозитория и замените плейсхолдеры:

| Плейсхолдер | Что подставить |
|-------------|---------------|
| `<SERVER_DOMAIN>` | Ваш домен (A-запись на VPS) |
| `<YOUR_UUID>` | UUID клиента из 3X-UI панели |
| `<SECRET_PATH>` | Секретный путь из inbound (например: `xhttp-keep-this-secret`) |

### 4. Серверная конфигурация

Серверная часть настраивается через 3X-UI панель:
- **Protocol**: VLESS
- **Transport**: xHTTP
- **Security**: TLS (с ACME-сертификатом через nginx)
- **Path**: тот же `/<SECRET_PATH>`

### 5. Проверка

```bash
# Тест подключения
curl -x socks5h://127.0.0.1:10808 https://ifconfig.me

# Проверка ECH
curl -x socks5h://127.0.0.1:10808 https://crypto.cloudflare.com/cdn-cgi/trace
# В выводе должно быть: sni=encrypted
```

---

## Диагностика проблем

### Соединение обрывается при handshake

1. Включить фрагментацию: добавить `dialerProxy: "fragment-proxy"` в sockopt основного outbound
2. Уменьшить `length` до `"1-1"` (максимально агрессивная фрагментация)
3. Увеличить `interval` до `"5-10"` (больше задержки между фрагментами)

### UDP-сервисы (мессенджеры) работают нестабильно

1. Проверить, что noise-udp outbound активен в routing
2. Попробовать увеличить диапазон noise: `"packet": "100-500"`
3. Проверить, не блокирует ли ISP QUIC (UDP 443) — в этом случае переключиться на TCP

### Медленная скорость

1. Проверить режим xHTTP: для TLS H2 должен быть stream-up
2. Увеличить `scMaxEachPostBytes` до `"1000000-2000000"`
3. Установить `"maxConcurrency": 1` для тестирования пропускной способности
4. Проверить, не идет ли трафик через fragment-proxy (он добавляет латентность)

### ECH не работает

1. Убедиться, что ech.dat скачан и лежит в `/usr/share/xray/`
2. Проверить DNS: используется DoH (1.1.1.1), а не системный DNS
3. Проверить актуальность ech.dat — обновляется каждые 12 часов

---

## Совместимость

| Клиент | xHTTP | ECH | Fragment | Noise |
|--------|-------|-----|----------|-------|
| Xray-core >= 25.1.1 | Yes | Yes | Yes | Yes |
| v2rayNG >= 1.9.x | Yes | Yes | Yes | Yes |
| Nekobox | Yes | Partial | Yes | Yes |
| Hiddify | Yes | Yes | Yes | Yes |
| Streisand (iOS) | Yes | Yes | Yes | No |

---

## Источники и ссылки

- [XHTTP: Beyond REALITY](https://github.com/XTLS/Xray-core/discussions/4113) — полная документация по xHTTP
- [singbox-ech-list](https://github.com/Akiyamov/singbox-ech-list) — база ECH-доменов (ech.dat)
- [Xray Freedom fragment](https://xtls.github.io/config/outbounds/freedom.html) — документация по фрагментации и noise
- [ECH Support PR](https://github.com/XTLS/Xray-core/pull/3813) — реализация ECH в Xray-core
- [XHTTP Padding Fix](https://github.com/XTLS/Xray-core/pull/5414) — кастомизация x_padding для обхода CDN-фильтров
