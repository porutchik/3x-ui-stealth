#!/usr/bin/env bash
#===============================================================================
# setup-3xui.sh — скрытый VPN-узел: 3x-ui (localhost) + nginx + VLESS(WS+TLS)
# за подставным доменом, по руководству:
#   https://telegra.ph/Polnoe-rukovodstvo-po-ustanovke-i-nastrojke-paneli-3X-UI-11-20
#
# Что делает:
#   * ставит 3x-ui неинтерактивно (случайные логин/пароль/порт/путь),
#     привязывает панель к 127.0.0.1, отключает HSTS (XUI_SKIP_HSTS=1)
#     и сервер подписок (порт 2096);
#   * ставит nginx с сайтом-заглушкой и сертификатом Let's Encrypt;
#   * создаёт клиент VLESS+WebSocket+TLS через API 3x-ui;
#   * панель и VLESS проксируются nginx'ом на одном порту 443, HSTS нигде
#     не включён и заголовок от панели скрывается;
#   * в конце печатает адрес панели, логин/пароль, ссылку vless:// и QR-код.
#
# Запуск (Ubuntu 22.04/24.04, Debian 12; root):
#   bash <(curl -Ls https://raw.githubusercontent.com/porutchik/3x-ui-stealth/main/setup-3xui.sh)
#   curl -Ls https://raw.githubusercontent.com/porutchik/3x-ui-stealth/main/setup-3xui.sh | bash
#
# Неинтерактивно (для автоматизации):
#   setup-3xui.sh -d example.com [-c имя-клиента] [-y] [-w] [-t ws|xhttp]
#     -w — не устанавливать блокировку торрентов (по умолчанию она ставится)
#     -t — транспорт VLESS: xhttp (по умолчанию) или ws (легаси, deprecated в xray)
#
# Повторный запуск на уже установленной 3x-ui панели запрещён
# (сначала: x-ui uninstall).
#===============================================================================
set -Eeuo pipefail
# ssh протаскивает LANG/LC_* клиента — на свежем сервере нужных локалей нет и
# perl/debconf сыплют предупреждениями; C.UTF-8 выводит кириллицу без проблем
export LANG=C.UTF-8 LC_ALL=C.UTF-8

XUI_INSTALL_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
DECOY_TEMPLATE_URL="https://html5up.net/aerial/download"
SELFSTEAL_DIR="/var/www/selfsteal"
NGINX_CONF="/etc/nginx/conf.d/selfsteal.conf"
ACCESS_FILE="/root/3x-ui-access.txt"

DOMAIN="" CLIENT_NAME="" ASSUME_YES=0 DO_FIREWALL=1 TRANSPORT="xhttp"
XFF_MARKER_VAL="" # значение секретного заголовка X-Real-Source (маркер доверия X-Forwarded-For)
PANEL_USER="" PANEL_PASS="" PANEL_PORT="" WEB_PATH="" API_TOKEN=""
INBOUND_PORT="" WS_PATH="" UUID=""
DOMAIN_IP="" PRIMARY_IP="" SECONDARY_IPS=""
SERVER_IPS=""
VLESS_URL="" PANEL_URL=""

C_G='\033[0;32m'; C_Y='\033[0;33m'; C_R='\033[0;31m'; C_B='\033[0;34m'; C_N='\033[0m'
log()  { echo -e "${C_G}[+]${C_N} $*"; }
info() { echo -e "${C_B}[i]${C_N} $*"; }
warn() { echo -e "${C_Y}[!]${C_N} $*" >&2; }
die()  { echo -e "${C_R}[x]${C_N} $*" >&2; exit 1; }
trap 'die "Ошибка на строке $LINENO — смотрите вывод выше"' ERR

#-------------------------------------------------------------------------------
# Утилиты
#-------------------------------------------------------------------------------

# случайная строка из [a-zA-Z0-9] заданной длины
rnd() {
    local out="" n=$1
    while [ "${#out}" -lt "$n" ]; do
        out+="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' || true)"
    done
    printf '%.*s' "$n" "$out"
}

# случайный свободный TCP-порт
rnd_free_port() {
    local p
    while :; do
        p=$(( (RANDOM % 55000) + 10000 ))
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${p}$" || { echo "$p"; return 0; }
    done
}

# случайные строчные буквы заданной длины (для имени клиента)
rnd_lower() {
    local out="" n=$1
    while [ "${#out}" -lt "$n" ]; do
        out+="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'a-z' || true)"
    done
    printf '%.*s' "$n" "$out"
}

# read с /dev/tty: при `curl ... | bash` stdin занят самим скриптом
tty_read() {
    if [ -t 0 ]; then
        IFS= read -r "$@"
    elif [ -r /dev/tty ]; then
        IFS= read -r "$@" < /dev/tty
    else
        warn "нет интерактивного ввода (stdin — не терминал, /dev/tty недоступен)"
        return 1
    fi
}

ask() { # ask "Вопрос" [дефолт] → ответ в $REPLY
    local prompt=$1 def=${2:-}
    if [ -n "$def" ]; then
        tty_read -r -p "$prompt [$def]: " REPLY || die "нет ввода"
        REPLY=${REPLY:-$def}
    else
        tty_read -r -p "$prompt: " REPLY || die "нет ввода"
    fi
}

confirm() { # confirm "Вопрос" → 0 если y/да, иначе 1 (дефолт — нет)
    local ans=""
    tty_read -r -p "$1 [y/N]: " ans || ans=n
    [[ "${ans,,}" == y || "${ans,,}" == "да" ]]
}

confirm_yes() { # confirm_yes "Вопрос" → 0 если пусто/y/да (дефолт — да)
    local ans=""
    tty_read -r -p "$1 [Y/n]: " ans || ans=y
    [[ -z "${ans,,}" || "${ans,,}" == y || "${ans,,}" == "да" ]]
}

resolve4() { # резолв ТОЛЬКО по внешнему DNS (dig), минуя /etc/hosts и локальный стаб:
    local d=$1 a="" ns #  # локальная связка в hosts не должна подменять A-запись
    if command -v dig >/dev/null 2>&1; then
        for ns in 1.1.1.1 8.8.8.8; do
            a=$(dig +short +time=2 +tries=1 "@$ns" "$d" A 2>/dev/null \
                | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -n1 || true)
            [ -n "$a" ] && { printf '%s' "$a"; return 0; }
        done
    fi
    getent ahostsv4 "$d" 2>/dev/null | awk '{print $1; exit}' || true # деградация без dig
    return 0
}

# Убрать из /etc/hosts связку имя→IP: образы VPS часто прописывают там основной
# IP под hostname/доменом, из-за чего getent ложно резолвит домен в него вместо
# настоящей DNS-записи (nginx тогда вешается не на тот IP, certbot не проходит).
clean_hosts_binding() {
    local name=$1 esc bak
    esc=${name//./\\.}
    if grep -qE "[[:space:]]${esc}([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
        bak="/etc/hosts.bak.3xui.$(date +%Y%m%d-%H%M%S).$$"
        cp -a /etc/hosts "$bak"
        sed -i -E "/[[:space:]]${esc}([[:space:]]|\$)/d" /etc/hosts
        info "Из /etc/hosts удалена связка с '$name' — домен резолвится по DNS (бэкап: $bak)"
    fi
}

is_server_ip() {
    local ip=$1 x
    for x in $SERVER_IPS; do [ "$x" = "$ip" ] && return 0; done
    return 1
}

wait_url() { # ждать HTTP 200; $2 — таймаут в секундах, $3 — обязательный Host
    local url=$1 t=${2:-60} host=${3:-} i c
    for i in $(seq 1 "$t"); do
        if [ -n "$host" ]; then
            c=$(curl -s -H "Host: $host" -o /dev/null -w '%{http_code}' "$url" || true)
        else
            c=$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)
        fi
        [ "$c" = "200" ] && return 0
        sleep 1
    done
    return 1
}

usage() {
    sed -n '2,30p' "$0" 2>/dev/null || true
    echo "Использование: setup-3xui.sh [-d домен] [-c имя-клиента] [-y] [-w] [-t ws|xhttp]"
    echo "  -d домен        подставной домен (A-запись → IP сервера)"
    echo "  -c имя          имя клиента/подключения (по умолчанию: <код страны><6 букв>, напр. NLqwfxz)"
    echo "  -y              не задавать вопросов"
    echo "  -w              не устанавливать блокировку торрентов"
    echo "  -t транспорт    xhttp (по умолчанию) или ws (легаси)"
    exit 1
}

#-------------------------------------------------------------------------------
# Аргументы и проверки окружения
#-------------------------------------------------------------------------------

while getopts ":d:c:ywt:" o; do
    case "$o" in
        d) DOMAIN=$OPTARG ;;
        c) CLIENT_NAME=$OPTARG ;;
        y) ASSUME_YES=1 ;;
        w) DO_FIREWALL=0 ;;
        t) TRANSPORT=$OPTARG ;;
        *) usage ;;
    esac
done
case "$TRANSPORT" in xhttp|ws) ;; *) die "неизвестный транспорт '-t $TRANSPORT' (доступны: xhttp, ws)" ;; esac

[ "$(id -u)" -eq 0 ] || die "Запустите от root (sudo -i)"
. /etc/os-release 2>/dev/null || true
case "${ID:-}" in ubuntu|debian) ;; *)
    warn "ОС '${ID:-unknown}' не тестировалась — рассчитано на Ubuntu 22.04/24.04, Debian 12" ;;
esac
command -v systemctl >/dev/null 2>&1 || die "не найден systemd"
[ -e /usr/local/x-ui ] && die "3x-ui уже установлена (/usr/local/x-ui). Для перенастройки сначала: x-ui uninstall"
command -v ss >/dev/null 2>&1 || die "не найдена утилита ss (iproute2)"

#-------------------------------------------------------------------------------
# Факты о сети сервера
#-------------------------------------------------------------------------------

SERVER_IPS=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
[ -n "$SERVER_IPS" ] || die "на сервере нет глобальных IPv4-адресов"
PRIMARY_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -n "$PRIMARY_IP" ] || PRIMARY_IP=$(echo "$SERVER_IPS" | head -n1)
# || true обязателен: при единственном IP сервера grep -vx не находит строк и
# возвращает 1 — без этого set -e падает сразу здесь
SECONDARY_IPS=$(echo "$SERVER_IPS" | grep -vx "$PRIMARY_IP" | tr '\n' ' ' || true)

info "IP сервера: $(echo "$SERVER_IPS" | tr '\n' ' ')"
info "Основной IP: $PRIMARY_IP${SECONDARY_IPS:+; вторичный(е): $SECONDARY_IPS}"

#-------------------------------------------------------------------------------
# Зависимости (ставим до выбора домена: нужна dnsutils/dig для честного резолва)
#-------------------------------------------------------------------------------

# unattended-upgrades держит dpkg-лок: пока он работает, не поставится ни один
# пакет. Ждём его завершения явно (штатный хелпер unattended-upgrade-shutdown,
# висящий в системе постоянно, лок НЕ держит — паттерн его отсекает).
# apt-таймаут ниже остаётся страховкой от прочих держателей лока.
wait_unattended_upgrades() {
    local waited=0
    while pgrep -f 'unattended-upgrade($| )' >/dev/null 2>&1; do
        if [ "$waited" = 0 ]; then
            log "Работает unattended-upgrades — жду завершения (пока он держит лок apt, пакеты не ставятся)"
        fi
        if [ "$waited" -ge 600 ]; then
            die "unattended-upgrades не завершился за 10 минут. Запустите скрипт позже либо остановите его: systemctl stop unattended-upgrades.service"
        fi
        sleep 10
        waited=$((waited + 10))
    done
    if [ "$waited" -gt 0 ]; then
        log "unattended-upgrades завершился (ждали ${waited} с) — продолжаю"
    fi
    return 0
}
wait_unattended_upgrades

log "Установка пакетов: nginx, certbot, dig (dnsutils), jq, qrencode, sqlite3, unzip"
export DEBIAN_FRONTEND=noninteractive
# DPkg::Lock::Timeout — ждать до 5 минут, если apt/dpkg занят (напр., unattended-upgrades)
APT_OPTS="-o DPkg::Lock::Timeout=300"
apt-get $APT_OPTS update -qq
apt-get $APT_OPTS install -y -qq nginx certbot python3-certbot-nginx curl unzip jq qrencode sqlite3 dnsutils \
    >/root/setup-apt.log 2>&1 \
    || { tail -n 20 /root/setup-apt.log >&2; die "apt-get install не удался (лог: /root/setup-apt.log)"; }

#-------------------------------------------------------------------------------
# Выбор подставного домена
#-------------------------------------------------------------------------------

# если hostname сервера уже резолвится в один из его IP — предложить его
# (проверка — по DNS через dig, локальная /etc/hosts-запись на неё не влияет;
#  сам /etc/hosts не трогаем, пока домен не выбран)
HN=$(hostname -f 2>/dev/null || true)
DEFAULT_DOMAIN=""
if [ -n "$HN" ]; then
    HIP=$(resolve4 "$HN")
    if [ -n "$HIP" ] && is_server_ip "$HIP"; then
        DEFAULT_DOMAIN="$HN"
        info "Hostname сервера ($HN) резолвится в $HIP — IP этого сервера, предложу его доменом по умолчанию."
    fi
fi

attempts=0
while :; do
    if [ -z "$DOMAIN" ]; then
        [ "$ASSUME_YES" = 1 ] && die "неинтерактивный режим требует -d <домен>"
        ask "Подставной домен (его A-запись должна указывать на IP этого сервера)" "$DEFAULT_DOMAIN"
        DOMAIN=$REPLY
    fi

    if [[ ! "$DOMAIN" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+[A-Za-z]{2,}$ ]]; then
        warn "'$DOMAIN' не похоже на домен"
    else
        clean_hosts_binding "$DOMAIN"
        DOMAIN_IP=$(resolve4 "$DOMAIN")
        if [ -z "$DOMAIN_IP" ]; then
            warn "домен '$DOMAIN' не резолвится"
        elif ! is_server_ip "$DOMAIN_IP"; then
            warn "домен '$DOMAIN' резолвится в $DOMAIN_IP — это не IP этого сервера ($(echo "$SERVER_IPS" | tr '\n' ' ')); сертификат Let's Encrypt не выпустится"
        else
            break # домен валиден и указывает на этот сервер
        fi
    fi

    DOMAIN=""
    attempts=$((attempts + 1))
    if [ "$ASSUME_YES" = 1 ] || [ "$attempts" -ge 3 ]; then
        die "не удалось получить домен, корректно указывающий на этот сервер"
    fi
done

# предупреждение про основной IP (рекомендация — вторичный)
if [ "$DOMAIN_IP" = "$PRIMARY_IP" ]; then
    warn "Домен '$DOMAIN' указывает на ОСНОВНОЙ IP сервера ($PRIMARY_IP)."
    if [ -n "$SECONDARY_IPS" ]; then
        warn "Рекомендуется сменить A-запись на вторичный IP:$SECONDARY_IPS"
        warn "основной IP VPS обычно уже известен блокировщикам/сканерам, вторичный — нет."
    else
        info "Это единственный IP сервера — перевести домен на вторичный нет возможности."
    fi
    if [ "$ASSUME_YES" != 1 ]; then
        confirm "Продолжить с $DOMAIN → $DOMAIN_IP?" \
            || die "Отмена. Смените A-запись домена на вторичный IP и запустите скрипт снова."
    fi
fi

#-------------------------------------------------------------------------------
# Сайт-заглушка (шаблон Aerial, как в руководстве)
#-------------------------------------------------------------------------------

log "Сайт-заглушка: $SELFSTEAL_DIR"
mkdir -p "$SELFSTEAL_DIR"
if curl -fL --retry 3 -o /tmp/selfsteal-aerial.zip "$DECOY_TEMPLATE_URL" >/root/selfsteal-dl.log 2>&1 \
   && unzip -oq /tmp/selfsteal-aerial.zip -d "$SELFSTEAL_DIR" 2>>/root/selfsteal-dl.log \
   && [ -f "$SELFSTEAL_DIR/index.html" ]; then
    log "Шаблон Aerial распакован"
else
    warn "Не удалось скачать шаблон Aerial — использую минимальную заглушку"
    cat > "$SELFSTEAL_DIR/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>It works!</title></head>
<body><h1>It works!</h1><p>This is the default web page.</p></body>
</html>
EOF
fi

#-------------------------------------------------------------------------------
# Установка 3x-ui (неинтерактивно, SQLite, без SSL — TLS терминирует nginx)
#-------------------------------------------------------------------------------

PANEL_USER=$(rnd 10)
PANEL_PASS=$(rnd 16)
PANEL_PORT=$(rnd_free_port)
WEB_PATH="/$(rnd 18)/"

log "Установка 3x-ui: порт 127.0.0.1:$PANEL_PORT, webPath $WEB_PATH"
curl -fLs "$XUI_INSTALL_URL" -o /tmp/xui-install.sh || die "не удалось скачать install.sh 3x-ui"
XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_SSL_MODE=none XUI_ENABLE_FAIL2BAN=false \
    XUI_USERNAME="$PANEL_USER" XUI_PASSWORD="$PANEL_PASS" \
    XUI_PANEL_PORT="$PANEL_PORT" XUI_WEB_BASE_PATH="$WEB_PATH" \
    bash /tmp/xui-install.sh >/root/xui-install.log 2>&1 || {
        tail -n 30 /root/xui-install.log >&2
        die "установка 3x-ui не удалась (лог: /root/xui-install.log)"
    }

# креды перечитываем из результата установки — источник истины
getenv() { grep "^$1=" /etc/x-ui/install-result.env 2>/dev/null | head -n1 | cut -d= -f2- || true; }
PANEL_USER=$(getenv XUI_USERNAME)
PANEL_PASS=$(getenv XUI_PASSWORD)
PANEL_PORT=$(getenv XUI_PANEL_PORT)
WEB_PATH=$(getenv XUI_WEB_BASE_PATH)
API_TOKEN=$(getenv XUI_API_TOKEN)
[ -n "$API_TOKEN" ] && [ -n "$PANEL_PORT" ] && [ -n "$WEB_PATH" ] \
    || die "не нашёл креды/токен в /etc/x-ui/install-result.env"

#-------------------------------------------------------------------------------
# Панель: без HSTS, без сервера подписок, только localhost.
# Все правки вносятся до единственного рестарта (частые рестарты упираются
# в start rate-limit systemd и откладывают старт на минуты).
#-------------------------------------------------------------------------------

# HSTS в 3x-ui выключаем через env сервиса (в nginx его не включаем вообще)
mkdir -p /etc/default
grep -q '^XUI_SKIP_HSTS=1$' /etc/default/x-ui 2>/dev/null || echo 'XUI_SKIP_HSTS=1' >> /etc/default/x-ui

# панель уже запущена установщиком (пока на 0.0.0.0, снаружи закрыто случайными
# портом/путем/паролем); через loopback API доступен сразу
wait_url "http://127.0.0.1:${PANEL_PORT}${WEB_PATH}" 60 || die "панель 3x-ui не поднялась после установки"

API_BASE="http://127.0.0.1:${PANEL_PORT}${WEB_PATH%/}"
# панель отвергает запросы с чужим Host (защита webDomain) — всегда шлём правильный
panel_curl() { curl -sf -H "Host: $DOMAIN" -H "Authorization: Bearer $API_TOKEN" "$@"; }

log "Настройки панели через API: отключаю сервер подписок (порт 2096), задаю домен"
SETTINGS_FORM=$(panel_curl -X POST "$API_BASE/panel/api/setting/all" \
    | jq -r --arg dom "$DOMAIN" \
        '.obj | .subEnable=false | .webDomain=$dom | .remarkTemplate="{{EMAIL}}"
         | to_entries | map("\(.key)=\(.value|tostring|@uri)") | join("&")') \
    || die "API: не удалось прочитать настройки панели"
panel_curl -X POST --data-binary "$SETTINGS_FORM" "$API_BASE/panel/api/setting/update" >/dev/null \
    || die "API: не удалось применить настройки панели"

log "Привязка панели к 127.0.0.1 (требование скрытности) и рестарт"
/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 >/dev/null
systemctl reset-failed x-ui 2>/dev/null || true
sleep 2
systemctl restart x-ui
wait_url "http://127.0.0.1:${PANEL_PORT}${WEB_PATH}" 180 "$DOMAIN" \
    || die "панель 3x-ui не поднялась на 127.0.0.1:$PANEL_PORT"

BAD_LISTENERS=$(ss -tlnp | grep '"x-ui"' | grep -v '127\.0\.0\.1:' || true)
[ -z "$BAD_LISTENERS" ] || die "панель слушает не только localhost: $BAD_LISTENERS"

#-------------------------------------------------------------------------------
# nginx (HTTP) + сертификат Let's Encrypt
#-------------------------------------------------------------------------------

log "nginx: HTTP-vhost и выпуск сертификата для $DOMAIN"
rm -f /etc/nginx/sites-enabled/default # дефолтный сайт светился бы на остальных IP
cat > "$NGINX_CONF" <<EOF
# Сгенерировано setup-3xui.sh (этап 1: HTTP + ACME)
server {
    listen ${DOMAIN_IP}:80;
    server_name ${DOMAIN};
    root ${SELFSTEAL_DIR};
    index index.html;
}
EOF
nginx -t 2>/dev/null || { nginx -t; die "nginx -t"; }
systemctl enable --now nginx >/dev/null 2>&1 || true
# именно restart: при reload nginx не может перевязать 0.0.0.0:80 → IP:80
# (Address already in use), и продолжает раздавать старый дефолтный сайт
systemctl restart nginx
systemctl is-active --quiet nginx || die "nginx не запустился"

# убеждаемся, что наш vhost реально обслуживает webroot — до траты лимитов Let's Encrypt
mkdir -p "$SELFSTEAL_DIR/.well-known/acme-challenge"
echo "setup-probe-ok" > "$SELFSTEAL_DIR/.well-known/acme-challenge/probe-check"
PROBE=$(curl -s --resolve "${DOMAIN}:80:${DOMAIN_IP}" "http://${DOMAIN}/.well-known/acme-challenge/probe-check")
[ "$PROBE" = "setup-probe-ok" ] \
    || die "http://${DOMAIN}/.well-known/... не обслуживается из $SELFSTEAL_DIR (проверьте A-запись и порт 80)"

certbot certonly --webroot -w "$SELFSTEAL_DIR" -d "$DOMAIN" \
    --register-unsafely-without-email --agree-tos -n --keep-until-expiring \
    || die "certbot не смог выпустить сертификат: домен должен указывать на ${DOMAIN_IP}, порт 80 — быть доступным извне"

# автопродление: certbot.timer запускает 'certbot renew', хук перезагружает nginx
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

#-------------------------------------------------------------------------------
# Инбаунд VLESS (xhttp|ws) через API (xray слушает 127.0.0.1, TLS терминирует nginx)
#-------------------------------------------------------------------------------

INBOUND_PORT=$(rnd_free_port)
WS_PATH="/$(rnd 10)"
UUID=$(cat /proc/sys/kernel/random/uuid)
XFF_MARKER_VAL=$(rnd 24)

# имя клиента по умолчанию: код страны сервера (ipinfo.io) + 6 случайных букв,
# например NLqwfxz — удобно, когда узлов несколько
if [ -z "$CLIENT_NAME" ]; then
    CC=$(curl -fs --max-time 10 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' || true)
    [[ "$CC" =~ ^[A-Z]{2}$ ]] || CC="XX"
    CLIENT_NAME="${CC}$(rnd_lower 6)"
    info "Имя клиента по умолчанию: $CLIENT_NAME (геолокация сервера: $CC)"
fi

log "Создание подключения VLESS+$TRANSPORT через API: 127.0.0.1:$INBOUND_PORT, путь $WS_PATH, клиент '$CLIENT_NAME'"
# subId нужен панели для генерации ссылок/QR клиента (без него — «у этого клиента нет subId»)
VLESS_SETTINGS=$(jq -nc --arg id "$UUID" --arg email "$CLIENT_NAME" --arg sub "$(rnd 16)" \
    '{clients:[{id:$id, flow:"", email:$email, subId:$sub, enable:true}], decryption:"none"}')
# host — нативное поле (не headers.Host: тот формат deprecated в xray);
# sockopt.trustedXForwardedFor — имена заголовков-маркеров, при наличии которых
# xray доверяет X-Forwarded-For (маркер X-Real-Source ставит только nginx)
if [ "$TRANSPORT" = "xhttp" ]; then
    VLESS_STREAM=$(jq -nc --arg p "$WS_PATH" --arg dom "$DOMAIN" \
        '{network:"xhttp", security:"none", xhttpSettings:{path:$p, host:$dom, mode:"auto"},
          sockopt:{trustedXForwardedFor:["X-Real-Source"]}}')
else
    VLESS_STREAM=$(jq -nc --arg p "$WS_PATH" --arg dom "$DOMAIN" \
        '{network:"ws", security:"none", wsSettings:{path:$p, host:$dom},
          sockopt:{trustedXForwardedFor:["X-Real-Source"]}}')
fi
VLESS_SNIFF=$(jq -nc '{enabled:true, destOverride:["http","tls"]}')

ADD_RES=$(panel_curl -X POST \
    --data-urlencode "up=0" --data-urlencode "down=0" --data-urlencode "total=0" \
    --data-urlencode "remark=$CLIENT_NAME" --data-urlencode "enable=true" --data-urlencode "expiryTime=0" \
    --data-urlencode "listen=127.0.0.1" --data-urlencode "port=$INBOUND_PORT" --data-urlencode "protocol=vless" \
    --data-urlencode "settings=$VLESS_SETTINGS" --data-urlencode "streamSettings=$VLESS_STREAM" \
    --data-urlencode "sniffing=$VLESS_SNIFF" \
    "$API_BASE/panel/api/inbounds/add") || die "API: не удалось создать инбаунд"
echo "$ADD_RES" | jq -e '.success == true' >/dev/null || die "API вернул ошибку: $ADD_RES"
INBOUND_ID=$(echo "$ADD_RES" | jq -r '.obj.id')
[ -n "$INBOUND_ID" ] && [ "$INBOUND_ID" != "null" ] || die "API не вернул id инбауна: $ADD_RES"

# Хост (внешний адрес подключения): без него панель генерирует ссылки на
# голый инбаунд (порт xray, security=none, без sni) — см. «Хосты» в руководстве
log "Добавление Хоста для инбауна: $DOMAIN:443, TLS, SNI, fingerprint chrome"
HOST_PAYLOAD=$(jq -nc --arg d "$DOMAIN" --argjson iid "$INBOUND_ID" \
    '{remark:$name, inboundIds:[$iid], hosts:[$d+":443"], security:"tls", sni:$d, fingerprint:"chrome"}' \
    --arg name "$CLIENT_NAME")
HOST_RES=$(panel_curl -X POST -H 'Content-Type: application/json' --data-binary "$HOST_PAYLOAD" \
    "$API_BASE/panel/api/hosts/add") || die "API: не удалось добавить Хост"
echo "$HOST_RES" | jq -e '.success == true' >/dev/null || die "API Хоста вернул ошибку: $HOST_RES"

sleep 2
ss -tln | grep -q "127\.0\.0\.1:${INBOUND_PORT}" || warn "xray не слушает 127.0.0.1:$INBOUND_PORT — проверьте инбаунд в панели"

# панель должна генерировать ссылку с TLS/SNI домена (а не голый инбаунд)
GEN_LINK=$(panel_curl "$API_BASE/panel/api/inbounds/allLinks" | jq -r '.obj[0] // empty' || true)
[ -n "$GEN_LINK" ] && echo "$GEN_LINK" | grep -q "sni=${DOMAIN}" \
    || warn "панель генерирует ссылку без TLS-хоста — проверьте раздел «Хосты» в панели"

#-------------------------------------------------------------------------------
# nginx: финальный конфиг — TLS, заглушка, панель и VLESS на одном порту 443
#-------------------------------------------------------------------------------

log "nginx: финальный конфиг (TLS, без HSTS)"
# локейшн подключения зависит от транспорта:
#  xhttp ходит по /путь/<uuid-сессии>/<seq> → префиксный location, без Upgrade,
#  buffering выкл в обе стороны; ws → точный location + websocket-guard (из инструкции).
# X-Forwarded-For перезаписываем (не append — иначе клиент подделает первую запись),
# X-Real-Source — секретный маркер: только nginx его ставит, xray по нему доверяет XFF.
if [ "$TRANSPORT" = "xhttp" ]; then
    VLESS_LOCATION=$(cat <<EOF
    # --- VLESS+xhttp → xray (префикс: запросы вида ${WS_PATH}/<сессия>/<seq>) ---
    location ${WS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${INBOUND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Real-Source ${XFF_MARKER_VAL};
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_cache off;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
    }
EOF
)
else
    VLESS_LOCATION=$(cat <<EOF
    # --- VLESS+WS → xray (не-websocket запросы получают 404) ---
    location = ${WS_PATH} {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${INBOUND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Real-Source ${XFF_MARKER_VAL};
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
    }
EOF
)
fi

cat > "$NGINX_CONF" <<EOF
# Сгенерировано setup-3xui.sh: подставной сайт + панель 3x-ui + VLESS(WS) за одним 443
# nginx слушает ТОЛЬКО на IP домена — сертификат не светится на остальных IP сервера.

server {
    listen ${DOMAIN_IP}:80;
    server_name ${DOMAIN};

    # продолжение HTTP-01 проверок при автопродлении сертификата
    location ^~ /.well-known/acme-challenge/ {
        root ${SELFSTEAL_DIR};
    }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen ${DOMAIN_IP}:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;

    # HSTS намеренно НЕ включаем; заголовок от панели (если появится) — скрываем
    proxy_hide_header Strict-Transport-Security;

    root  ${SELFSTEAL_DIR};
    index index.html;

    # --- панель 3x-ui по секретному webPath ---
    location = ${WEB_PATH%/} { return 301 https://\$host${WEB_PATH}; }
    location ${WEB_PATH} {
        proxy_pass http://127.0.0.1:${PANEL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 600s;
    }

${VLESS_LOCATION}

    # всем остальным — сайт-заглушка
    location / { try_files \$uri \$uri/ =404; }
}
EOF
nginx -t 2>/dev/null || { nginx -t; die "nginx -t после финального конфига"; }
systemctl restart nginx
systemctl is-active --quiet nginx || die "nginx не перезапустился с финальным конфигом"

#-------------------------------------------------------------------------------
# Файрвол: блокировка торрентов (опционально; правила IPv4, только точечные DROP,
# SSH/80/443/панель не затрагиваются). Персистентность — netfilter-persistent.
#-------------------------------------------------------------------------------

TORR_FW_STATUS="не установлена (флаг -w)"
if [ "$DO_FIREWALL" = 1 ]; then
    if [ "$ASSUME_YES" != 1 ]; then
        confirm_yes "Установить блокировку торрентов (iptables + автозагрузка)" || DO_FIREWALL=0
    fi
fi
if [ "$DO_FIREWALL" = 1 ]; then
    log "Файрвол: блокировка торрентов (DHT, трекеры, Zona, порты 6881/51500, SMTP 25)"
    CH_IN=setup3xui_torr_in
    CH_OUT=setup3xui_torr_out
    iptables -N "$CH_IN" 2>/dev/null || true
    iptables -N "$CH_OUT" 2>/dev/null || true
    iptables -F "$CH_IN"
    iptables -F "$CH_OUT"
    # INPUT
    iptables -A "$CH_IN" -s 85.217.140.0/24 -j DROP
    iptables -A "$CH_IN" -s 85.217.149.0/24 -j DROP
    iptables -A "$CH_IN" -p udp -m udp --sport 6881 -j DROP
    iptables -A "$CH_IN" -p udp -m string --string get_peers --algo kmp -j DROP
    iptables -A "$CH_IN" -p udp -m string --string find_node --algo kmp -j DROP
    # OUTPUT (строки с пробелами обязаны быть в кавычках: --string "GET /ann?")
    iptables -A "$CH_OUT" -m string --string "GET /ann?" --algo kmp -j DROP
    iptables -A "$CH_OUT" -m string --string "GET /announce?" --algo kmp -j DROP
    iptables -A "$CH_OUT" -m string --string "t: Zona" --algo kmp -j DROP
    iptables -A "$CH_OUT" -m string --string .opentrackr. --algo kmp -j DROP
    iptables -A "$CH_OUT" -p udp -m string --string /announce --algo kmp -j DROP
    iptables -A "$CH_OUT" -m string --string rutracker.cx --algo kmp -j DROP
    iptables -A "$CH_OUT" -m string --string .t-ru.org --algo kmp -j DROP
    iptables -A "$CH_OUT" -m string --string .openbittorrent. --algo kmp -j DROP
    iptables -A "$CH_OUT" -m string --string tr.kxmp.cf --algo kmp -j DROP
    iptables -A "$CH_OUT" -m string --string .abcvg. --algo kmp -j DROP
    iptables -A "$CH_OUT" -p udp -m udp --dport 6881 -j DROP
    iptables -A "$CH_OUT" -p udp -m string --string get_peers --algo kmp -j DROP
    iptables -A "$CH_OUT" -p udp -m string --string find_node --algo kmp -j DROP
    iptables -A "$CH_OUT" -m string --string .opentrackr. --algo kmp -j DROP # дубль из исходного списка, сохранён
    iptables -A "$CH_OUT" -p tcp -m tcp --dport 25 -j DROP
    iptables -A "$CH_OUT" -d 185.107.94.0/24 -j DROP
    iptables -A "$CH_OUT" -d 77.68.37.246/32 -j DROP
    iptables -A "$CH_OUT" -d 77.68.41.0/24 -j DROP
    iptables -A "$CH_OUT" -d 88.208.201.96/32 -j DROP
    iptables -A "$CH_OUT" -d 88.208.208.22/32 -j DROP
    iptables -A "$CH_OUT" -d 88.208.208.25/32 -j DROP
    iptables -A "$CH_OUT" -d 88.208.218.105/32 -j DROP
    iptables -A "$CH_OUT" -d 88.208.218.118/32 -j DROP
    iptables -A "$CH_OUT" -d 88.208.218.99/32 -j DROP
    iptables -A "$CH_OUT" -d 88.208.228.110/32 -j DROP
    iptables -A "$CH_OUT" -d 88.208.228.143/32 -j DROP
    iptables -A "$CH_OUT" -d 88.208.228.157/32 -j DROP
    iptables -A "$CH_OUT" -d 88.208.229.138/32 -j DROP
    iptables -A "$CH_OUT" -d 45.153.34.149/32 -j DROP
    iptables -A "$CH_OUT" -d 45.153.34.235/32 -j DROP
    iptables -A "$CH_OUT" -d 91.92.40.200/32 -j DROP
    iptables -A "$CH_OUT" -d 91.92.40.202/32 -j DROP
    iptables -A "$CH_OUT" -d 104.156.155.0/24 -j DROP
    iptables -A "$CH_OUT" -p tcp -m tcp --dport 51500 -j DROP
    # подключаем цепочки в самое начало INPUT/OUTPUT
    iptables -C INPUT -j "$CH_IN" 2>/dev/null || iptables -I INPUT 1 -j "$CH_IN"
    iptables -C OUTPUT -j "$CH_OUT" 2>/dev/null || iptables -I OUTPUT 1 -j "$CH_OUT"
    # автозагрузка после ребута
    echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections
    echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
    apt-get $APT_OPTS install -y -qq iptables-persistent >/root/setup-iptables.log 2>&1 \
        || { tail -n 10 /root/setup-iptables.log >&2; die "не удалось установить iptables-persistent (лог: /root/setup-iptables.log)"; }
    netfilter-persistent save >/dev/null 2>&1 \
        || warn "правила применены, но netfilter-persistent save не удался — после ребута их не будет"
    TORR_FW_STATUS="установлена (IPv4, автозагрузка: netfilter-persistent)"
else
    info "Блокировка торрентов пропущена (-w)"
fi

#-------------------------------------------------------------------------------
# Самопроверка
#-------------------------------------------------------------------------------

log "Самопроверка"
RESOLVE_ARG="${DOMAIN}:443:${DOMAIN_IP}"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$RESOLVE_ARG" "https://${DOMAIN}/")
[ "$CODE" = "200" ] || die "заглушка на https://${DOMAIN}/ отдала HTTP $CODE"

PANEL_HEADERS=$(curl -s -D - -o /dev/null --resolve "$RESOLVE_ARG" "https://${DOMAIN}${WEB_PATH}")
echo "$PANEL_HEADERS" | head -n1 | grep -q ' 200 ' \
    || die "панель недоступна по https://${DOMAIN}${WEB_PATH} ($(echo "$PANEL_HEADERS" | head -n1))"
echo "$PANEL_HEADERS" | grep -qi 'strict-transport-security' \
    && die "в ответах панели обнаружен HSTS — проверьте XUI_SKIP_HSTS и proxy_hide_header"

CODE=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$RESOLVE_ARG" "https://${DOMAIN}${WS_PATH}")
case "$CODE" in
    400|404) ;; # путь отвечает, но не пускает без клиентского рукопожатия — норма
    *) warn "путь $WS_PATH отдал HTTP $CODE (ожидался 400/404)" ;;
esac

certbot renew --dry-run >/dev/null 2>&1 \
    || warn "certbot renew --dry-run не прошёл — проверьте /var/log/letsencrypt/letsencrypt.log"

#-------------------------------------------------------------------------------
# Итог: ссылка vless://, QR-код, доступы
#-------------------------------------------------------------------------------

ENC_WS=$(printf '%s' "$WS_PATH" | jq -sRr @uri)
ENC_NAME=$(printf '%s' "$CLIENT_NAME" | jq -sRr @uri)
if [ "$TRANSPORT" = "xhttp" ]; then
    VLESS_URL="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=xhttp&mode=auto&host=${DOMAIN}&path=${ENC_WS}#${ENC_NAME}"
else
    VLESS_URL="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=${ENC_WS}#${ENC_NAME}"
fi
PANEL_URL="https://${DOMAIN}${WEB_PATH}"

{
    echo "==================================================================="
    echo " 3x-ui скрытый узел — доступы (сгенерировано $(date '+%Y-%m-%d %H:%M:%S'))"
    echo "==================================================================="
    echo "Домен:              $DOMAIN → $DOMAIN_IP"
    echo "Панель 3x-ui:       $PANEL_URL"
    echo "Логин:              $PANEL_USER"
    echo "Пароль:             $PANEL_PASS"
    echo "Порт панели:        127.0.0.1:$PANEL_PORT (только через nginx)"
    echo "-------------------------------------------------------------------"
    echo "Подключение VLESS:  $CLIENT_NAME"
    echo "Ссылка:             $VLESS_URL"
    echo "UUID:               $UUID"
    echo "Транспорт:          $TRANSPORT$( [ "$TRANSPORT" = "xhttp" ] && echo ' (mode=auto)' )"
    echo "Путь:               $WS_PATH"
    echo "Инбаунд:            127.0.0.1:$INBOUND_PORT (проксируется nginx :443)"
    echo "-------------------------------------------------------------------"
    echo "Файлы: nginx: $NGINX_CONF; БД панели: /etc/x-ui/x-ui.db (бэкап!)"
    echo "Сертификат: /etc/letsencrypt/live/$DOMAIN/ (продление: certbot renew"
    echo "             по таймеру certbot.timer, хук перезагружает nginx)"
    echo "Блокировка торрентов: $TORR_FW_STATUS"
    echo "==================================================================="
} | tee "$ACCESS_FILE" >/dev/null
chmod 600 "$ACCESS_FILE"

echo
echo -e "${C_B}═════════════════════════════════════════════════════════════════${C_N}"
echo -e " Готово. Скрытый узел 3x-ui + nginx развёрнут на ${C_G}${DOMAIN}${C_N}"
echo -e "${C_B}═════════════════════════════════════════════════════════════════${C_N}"
echo
echo -e " ${C_G}Панель 3x-ui:${C_N}"
echo -e "   адрес:   ${C_Y}${PANEL_URL}${C_N}"
echo -e "   логин:   ${C_Y}${PANEL_USER}${C_N}"
echo -e "   пароль:  ${C_Y}${PANEL_PASS}${C_N}"
echo
echo -e " ${C_G}Подключение VLESS ($CLIENT_NAME):${C_N}"
echo -e "   ${C_Y}${VLESS_URL}${C_N}"
echo
echo -e " ${C_G}QR-код подключения (наведите камеру приложения-клиента):${C_N}"
qrencode -t ANSIUTF8 -m 2 "$VLESS_URL" || warn "не удалось вывести QR (qrencode)"
echo
if [ "$DOMAIN_IP" = "$PRIMARY_IP" ] && [ -n "$SECONDARY_IPS" ]; then
    echo -e " ${C_Y}Напоминание:${C_N} домен указывает на основной IP ($PRIMARY_IP)."
    echo -e " Рекомендуется сменить A-запись на вторичный IP:$SECONDARY_IPS"
    echo -e " После смены A-записи обновите listen-IP в $NGINX_CONF и выполните:"
    echo -e "   systemctl reload nginx && certbot renew --force-renewal"
    echo
fi
echo -e " Доступы сохранены в ${C_Y}${ACCESS_FILE}${C_N} (chmod 600)."
echo -e " Транспорт VLESS: ${TRANSPORT}$( [ "$TRANSPORT" = "xhttp" ] && echo ' (mode=auto)' ); реальные IP клиентов"
echo -e " пробрасываются nginx'ом (X-Forwarded-For + секретный маркер X-Real-Source)."
echo -e " HSTS выключен (nginx: не включён, 3x-ui: XUI_SKIP_HSTS=1), сервер подписок отключен,"
echo -e " панель и xray слушают только 127.0.0.1, наружу — один порт 443 с заглушкой."
echo -e " Блокировка торрентов: $TORR_FW_STATUS."
echo
