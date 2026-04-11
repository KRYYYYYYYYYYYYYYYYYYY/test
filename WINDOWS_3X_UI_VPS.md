# 3x-ui-vps on Windows: practical runbook

Ниже минимальный и безопасный сценарий, чтобы запускать Linux-only skill `3x-ui-vps` с Windows через WSL.

## 1) Что установить на Windows

1. **WSL + Ubuntu** (обязательно):
   ```powershell
   wsl --install -d Ubuntu
   ```
2. **OpenSSH Client** (обычно уже есть в Windows 10/11):
   ```powershell
   ssh -V
   ```
3. **Ваш приватный SSH ключ** (`id_rsa` или `id_ed25519`) локально на ПК.
   - Никому не отправлять.

## 2) Что установить внутри WSL (Ubuntu)

Откройте Ubuntu (WSL) и выполните:

```bash
sudo apt update
sudo apt install -y python3 curl openssh-client ca-certificates
```

Проверки:

```bash
python3 --version
ssh -V
```

## 3) Быстрый preflight перед деплоем

Подготовьте значения:

- `HOST` = `root@<PUBLIC_IP>` (или `ubuntu@<PUBLIC_IP>`)
- `DOMAIN` = ваш домен, уже указывающий A-записью на VPS
- `PANEL_USER` = например `admin`
- `PANEL_PASS` = сильный пароль панели

Проверьте SSH-доступ:

```powershell
ssh -i C:\Users\<YOU>\.ssh\id_rsa root@<PUBLIC_IP> "echo ok"
```

## 4) Деплой 3x-ui-vps со стороны Windows (через WSL)

Запуск из PowerShell:

```powershell
$SkillDir = "/opt/codex/skills/3x-ui-vps"
$Host = "root@<PUBLIC_IP>"
$Domain = "<VPN_DOMAIN>"
$PanelUser = "admin"
$PanelPass = "<PANEL_PASSWORD>"

wsl -e bash -lc "cd $SkillDir && ./scripts/bootstrap-host.sh --host '$Host' --domain '$Domain' --panel-username '$PanelUser' --panel-password '$PanelPass'"
```

Если у VPS только password-auth, добавьте:

```powershell
$SshPass = "<SSH_PASSWORD>"
wsl -e bash -lc "cd $SkillDir && ./scripts/bootstrap-host.sh --host '$Host' --ssh-password '$SshPass' --domain '$Domain' --panel-username '$PanelUser' --panel-password '$PanelPass'"
```

## 5) Открыть туннель к панели (панель не публикуем)

```powershell
$SkillDir = "/opt/codex/skills/3x-ui-vps"
$Host = "root@<PUBLIC_IP>"

wsl -e bash -lc "cd $SkillDir && ./scripts/open-panel-tunnel.sh --host '$Host' --local-port 12053 --panel-port 2053"
```

После запуска откройте:

- <http://127.0.0.1:12053>

## 6) Создать первый inbound + первую VLESS-ссылку

```powershell
$SkillDir = "/opt/codex/skills/3x-ui-vps"
$PanelPass = "<PANEL_PASSWORD>"
$Domain = "<VPN_DOMAIN>"

wsl -e bash -lc "cd $SkillDir && python3 scripts/bootstrap-inbound.py --panel-url http://127.0.0.1:12053 --username admin --password '$PanelPass' --public-domain '$Domain' --backend-port 1234 --path /xhttp-keep-this-secret"
```

## 7) Добавить второго/третьего клиента (без нового inbound)

```powershell
$SkillDir = "/opt/codex/skills/3x-ui-vps"
$PanelPass = "<PANEL_PASSWORD>"

wsl -e bash -lc "cd $SkillDir && python3 scripts/add-inbound-client.py --panel-url http://127.0.0.1:12053 --username admin --password '$PanelPass' --inbound-id 1"
```

## 8) Что отправлять ассистенту, чтобы он вёл вас дальше

Отправляйте только безопасные данные:

- `HOST` (например, `root@1.2.3.4`)
- `DOMAIN`
- какой SSH-тип: `key` или `password`
- вывод команд (без секретов):
  - `ss -ltnp | egrep ":2053 |:2096 |:1234 |:80 |:443 "`
  - `docker compose -f /opt/3x-ui/docker-compose.yml ps`
  - `ufw status numbered`
  - `curl -I http://127.0.0.1:2053/`

Не отправляйте:

- приватный ключ (`id_rsa`, `id_ed25519`)
- пароли панели/SSH в открытом виде
- приватные ключи сертификатов/Reality

## 9) Обновление стека позже

```powershell
$SkillDir = "/opt/codex/skills/3x-ui-vps"
$Host = "root@<PUBLIC_IP>"

wsl -e bash -lc "cd $SkillDir && ./scripts/update-stack.sh --host '$Host'"
```
