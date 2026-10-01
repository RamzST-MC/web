#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Ошибка: запустите скрипт от root или через sudo${NC}"
    exit 1
fi

DOMAIN="test.ru"
WEB_ROOT="/var/www/$DOMAIN/html"
PHP_VER="8.4"
PHP_SOCK="/run/php/php${PHP_VER}-fpm.sock"
FTP_USER="ftpuser"
MYSQL_DB="xenforo_db"
MYSQL_USER="xenforo_user"
PASV_MIN=40000
PASV_MAX=40100

echo -e "${YELLOW}Генерация случайных паролей (без спецсимволов)...${NC}"
MYSQL_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
FTP_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
XENFORO_ADMIN_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
XENFORO_ADMIN_USER="admin"
XENFORO_ADMIN_EMAIL="admin@${DOMAIN}"
XENFORO_BOARD_TITLE="My XenForo Forum"

echo -e "${GREEN}Пароли сгенерированы.${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN} Nginx + PHP ${PHP_VER} + Redis + MariaDB + phpMyAdmin + FTP + XenForo${NC}"
echo -e "${GREEN}============================================${NC}"

# ==========================================================
#  1. Исправление репозиториев
# ==========================================================
echo -e "\n${YELLOW}[1/11] Исправление репозиториев и очистка кэша...${NC}"
grep -rl "ua.archive.ubuntu.com" /etc/apt/ 2>/dev/null | xargs sed -i 's/ua\.archive\.ubuntu\.com/archive.ubuntu.com/g' 2>/dev/null || true
grep -rl "ua.ports.ubuntu.com" /etc/apt/ 2>/dev/null | xargs sed -i 's/ua\.ports\.ubuntu\.com/ports.ubuntu.com/g' 2>/dev/null || true
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
apt-get clean
rm -rf /var/lib/apt/lists/*
export DEBIAN_FRONTEND=noninteractive
apt-get update -y --fix-missing
apt-get --fix-broken install -y

# ==========================================================
#  2. Базовые пакеты
# ==========================================================
echo -e "\n${YELLOW}[2/11] Подготовка окружения...${NC}"
apt-get install -y software-properties-common curl gnupg2 ca-certificates lsb-release iptables iptables-persistent unzip wget git
add-apt-repository -y ppa:ondrej/php
apt-get update -y

# ==========================================================
#  3. Установка стека (Nginx, PHP, Redis, MariaDB)
# ==========================================================
echo -e "\n${YELLOW}[3/11] Установка Nginx, PHP ${PHP_VER}-FPM, Redis, MariaDB...${NC}"
apt-get install -y \
nginx \
redis-server \
php${PHP_VER}-fpm \
php${PHP_VER}-cli \
php${PHP_VER}-common \
php${PHP_VER}-mysql \
php${PHP_VER}-curl \
php${PHP_VER}-gd \
php${PHP_VER}-mbstring \
php${PHP_VER}-xml \
php${PHP_VER}-zip \
php${PHP_VER}-intl \
php${PHP_VER}-opcache \
php${PHP_VER}-readline \
php${PHP_VER}-soap \
php${PHP_VER}-bcmath \
php${PHP_VER}-redis \
php${PHP_VER}-imagick

echo -e "${GREEN}Стек успешно установлен.${NC}"
php${PHP_VER} -v | head -n 1

# ==========================================================
#  4. Подготовка директорий
# ==========================================================
echo -e "\n${YELLOW}[4/11] Подготовка директорий...${NC}"
mkdir -p "$WEB_ROOT"

# ==========================================================
#  5. Установка XenForo с GitHub
# ==========================================================
echo -e "\n${YELLOW}[5/11] Установка XenForo с GitHub...${NC}"
TEMP_DIR="/tmp/xenforo-install"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

echo -e "${YELLOW}Скачивание XenForo из репозитория RamzST-MC/Xenforo...${NC}"
if git clone https://github.com/RamzST-MC/Xenforo.git xenforo 2>/dev/null; then
    echo -e "${GREEN}XenForo успешно загружен.${NC}"
else
    echo -e "${YELLOW}Скачиваем как ZIP архив...${NC}"
    wget -q -O xenforo.zip https://github.com/RamzST-MC/Xenforo/archive/refs/heads/main.zip
    unzip -q xenforo.zip
    mv Xenforo-main xenforo
fi

echo -e "${YELLOW}Копирование файлов в ${WEB_ROOT}...${NC}"
if [ -d "xenforo/upload" ]; then
    cp -r xenforo/upload/* "$WEB_ROOT/"
else
    cp -r xenforo/* "$WEB_ROOT/"
fi

echo -e "${YELLOW}Настройка прав доступа...${NC}"
chown -R www-data:www-data "$WEB_ROOT"
chmod -R 755 "$WEB_ROOT"
chmod -R 777 "$WEB_ROOT/data" 2>/dev/null || true
chmod -R 777 "$WEB_ROOT/internal_data" 2>/dev/null || true

cd /
rm -rf "$TEMP_DIR"

# ==========================================================
#  6. Установка и настройка MariaDB
# ==========================================================
echo -e "\n${YELLOW}[6/11] Настройка MariaDB...${NC}"
apt-get install -y mariadb-server mariadb-client
systemctl start mariadb
systemctl enable mariadb

echo -e "${YELLOW}Создание базы данных для XenForo...${NC}"
mysql -u root <<EOF
DROP USER IF EXISTS '${MYSQL_USER}'@'localhost';
DROP USER IF EXISTS '${MYSQL_USER}'@'%';
DROP DATABASE IF EXISTS ${MYSQL_DB};
CREATE DATABASE ${MYSQL_DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
CREATE USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASS}';
GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'%';
FLUSH PRIVILEGES;
EOF

echo -e "${GREEN}База данных ${MYSQL_DB} создана.${NC}"
echo -e "${YELLOW}Проверка подключения к MySQL...${NC}"
if mysql -u "${MYSQL_USER}" -p"${MYSQL_PASS}" -e "SELECT 1;" "${MYSQL_DB}" 2>/dev/null; then
    echo -e "${GREEN}✓ Подключение к MySQL успешно!${NC}"
else
    echo -e "${RED}✗ Ошибка подключения к MySQL!${NC}"
    exit 1
fi

# ==========================================================
#  7. Создание config.php (с подключенным Redis)
# ==========================================================
echo -e "\n${YELLOW}[7/11] Создание config.php (MySQL + Redis)...${NC}"
rm -f "$WEB_ROOT/src/config.php"
cat > "$WEB_ROOT/src/config.php" <<XENCONFIG
<?php
\$config['db']['host'] = 'localhost';
\$config['db']['port'] = 3306;
\$config['db']['username'] = '${MYSQL_USER}';
\$config['db']['password'] = '${MYSQL_PASS}';
\$config['db']['dbname'] = '${MYSQL_DB}';
\$config['db']['socket'] = null;
\$config['fullUnicode'] = true;

// Настройки Redis для кэширования
\$config['cache']['enabled'] = true;
\$config['cache']['provider'] = 'Redis';
\$config['cache']['config'] = [
    'host' => '127.0.0.1',
    'port' => 6379
];
XENCONFIG

chown www-data:www-data "$WEB_ROOT/src/config.php"
chmod 644 "$WEB_ROOT/src/config.php"

systemctl restart php${PHP_VER}-fpm

# ==========================================================
#  8. Настройка Nginx (Прямая работа с PHP-FPM, без Apache)
# ==========================================================
echo -e "\n${YELLOW}[8/11] Настройка Nginx для XenForo...${NC}"
cat <<NGINX_CONF > /etc/nginx/sites-available/${DOMAIN}
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};
    
    root ${WEB_ROOT};
    index index.php;
    
    client_max_body_size 100M;
    
    fastcgi_buffer_size 128k;
    fastcgi_buffers 4 256k;
    fastcgi_busy_buffers_size 256k;
    
    access_log /var/log/nginx/${DOMAIN}-access.log;
    error_log /var/log/nginx/${DOMAIN}-error.log;

    # Защита системных папок XenForo
    location ~* ^/(internal_data|src|library)/ {
        deny all;
    }
    location ~* /(composer\.json|composer\.lock|phpunit\.xml|\.git) {
        deny all;
    }
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Кэширование статики
    location ~* \.(jpg|jpeg|gif|png|css|js|ico|webp|tiff|ttf|svg|woff|woff2|eot|mp4|webm|ogg|mp3|wav|flac|pdf)\$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        log_not_found off;
        access_log off;
    }

    # Маршрутизация XenForo
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # Обработка PHP
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PHP_VALUE "upload_max_filesize=64M \n post_max_size=64M \n max_execution_time=300 \n max_input_time=300";
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }
}
NGINX_CONF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/

# ==========================================================
#  9. vsftpd + пассивный режим
# ==========================================================
echo -e "\n${YELLOW}[9/11] Установка vsftpd с пассивным режимом...${NC}"
apt-get install -y vsftpd
mkdir -p /etc/vsftpd

if [ -f "/etc/vsftpd.conf" ]; then
    CONF_FILE="/etc/vsftpd.conf"
else
    CONF_FILE="/etc/vsftpd/vsftpd.conf"
fi

[ -f "$CONF_FILE" ] && cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%s)"

cat <<EOF > "$CONF_FILE"
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=000
file_open_mode=0777
chroot_local_user=NO
allow_writeable_chroot=YES
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
pam_service_name=vsftpd
ssl_enable=NO
secure_chroot_dir=/var/run/vsftpd/empty
pasv_enable=YES
pasv_min_port=${PASV_MIN}
pasv_max_port=${PASV_MAX}
EOF

mkdir -p /var/run/vsftpd/empty
PAM_FILE="/etc/pam.d/vsftpd"
if [ -f "$PAM_FILE" ]; then
    sed -i 's/^auth[[:space:]]*required[[:space:]]*pam_shells\.so/#auth required pam_shells.so/' "$PAM_FILE"
fi

if ! grep -q "/usr/sbin/nologin" /etc/shells 2>/dev/null; then
    echo "/usr/sbin/nologin" >> /etc/shells
fi

if id "$FTP_USER" &>/dev/null; then
    usermod -u 0 -g root "$FTP_USER" 2>/dev/null || true
    usermod -aG root "$FTP_USER" 2>/dev/null || true
    usermod -s /usr/sbin/nologin "$FTP_USER"
    echo "$FTP_USER:$FTP_PASS" | chpasswd
else
    useradd -m -s /usr/sbin/nologin -u 0 -o -g root "$FTP_USER"
    echo "$FTP_USER:$FTP_PASS" | chpasswd
fi

# ==========================================================
#  10. phpMyAdmin + iptables NAT + Firewall
# ==========================================================
echo -e "\n${YELLOW}[10/11] Установка phpMyAdmin и настройка Firewall...${NC}"
debconf-set-selections <<< "phpmyadmin phpmyadmin/mysql/admin-pass password ${MYSQL_PASS}"
debconf-set-selections <<< "phpmyadmin phpmyadmin/mysql/app-pass password ${MYSQL_PASS}"
debconf-set-selections <<< "phpmyadmin phpmyadmin/dbconfig-install boolean true"
debconf-set-selections <<< "phpmyadmin phpmyadmin/reconfigure-webserver multiselect none"
apt-get install -y phpmyadmin

ln -sf /usr/share/phpmyadmin ${WEB_ROOT}/phpmyadmin

EXT_IF=$(ip route | grep default | awk '{print $5}' | head -1)
modprobe nf_conntrack_ftp
modprobe nf_nat_ftp 2>/dev/null || true
echo "nf_conntrack_ftp" > /etc/modules-load.d/ftp.conf
echo "nf_nat_ftp" >> /etc/modules-load.d/ftp.conf 2>/dev/null || true

PUBLIC_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "$DOMAIN")

iptables -t nat -A POSTROUTING -o $EXT_IF -p tcp --sport 20:21 -j SNAT --to-source $PUBLIC_IP 2>/dev/null || true
iptables -t nat -A POSTROUTING -o $EXT_IF -p tcp --dport ${PASV_MIN}:${PASV_MAX} -j SNAT --to-source $PUBLIC_IP 2>/dev/null || true

if command -v ufw &> /dev/null; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 20/tcp
    ufw allow 21/tcp
    ufw allow 22/tcp
    ufw allow 3306/tcp
    ufw allow ${PASV_MIN}:${PASV_MAX}/tcp
    ufw --force enable 2>/dev/null || true
fi
netfilter-persistent save 2>/dev/null || true

# ==========================================================
#  11. Перезапуск служб + ИНСТРУКЦИЯ ПО УСТАНОВКЕ
# ==========================================================
echo -e "\n${YELLOW}[11/11] Проверка и запуск служб...${NC}"
nginx -t
systemctl restart php${PHP_VER}-fpm nginx mariadb redis-server vsftpd
systemctl enable php${PHP_VER}-fpm nginx mariadb redis-server vsftpd

echo -e "\n${YELLOW}⚠ Автоустановка через CLI не поддерживается в этой сборке XenForo.${NC}"
echo -e "${YELLOW}Используйте веб-установщик (это займет 1 минуту):${NC}"
echo -e "${YELLOW}  1. Откройте в браузере: http://${DOMAIN}/install/ (рекомендуется режим инкогнито)${NC}"
echo -e "${YELLOW}  2. Нажмите 'Use these values' (данные БД и Redis уже подставлены из config.php)${NC}"
echo -e "${YELLOW}  3. На шаге создания администратора введите:${NC}"
echo -e "${YELLOW}     - User name: ${XENFORO_ADMIN_USER}${NC}"
echo -e "${YELLOW}     - Password: ${XENFORO_ADMIN_PASS}${NC}"
echo -e "${YELLOW}     - Email: ${XENFORO_ADMIN_EMAIL}${NC}"
echo -e "${YELLOW}  4. После завершения установки обязательно удалите папку /install/${NC}"

# ==========================================================
#  Итог - СОХРАНЯЕМ ПАРОЛИ В ФАЙЛ
# ==========================================================
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "не определён")
CREDENTIALS_FILE="/var/www/test.ru/server_credentials_${DOMAIN}.txt"

cat > "$CREDENTIALS_FILE" <<EOF
╔════════════════════════════════════════════════════════════╗
║              ДАННЫЕ ДОСТУПА ДЛЯ ${DOMAIN}
╚════════════════════════════════════════════════════════════╝
Дата создания : $(date)
Сервер        : ${DOMAIN}
Local IP      : ${LOCAL_IP}
Public IP     : ${PUBLIC_IP}
Стек          : Nginx + PHP-FPM + Redis + MariaDB

┌────────────────────────────────────────────────────────────┐
│ 🗄️  MYSQL / MARIADB
└────────────────────────────────────────────────────────────┘
Хост         : localhost
Порт         : 3306
База данных  : ${MYSQL_DB}
Пользователь : ${MYSQL_USER}
Пароль       : ${MYSQL_PASS}

┌────────────────────────────────────────────────────────────┐
│ 🧠 REDIS (Кэш)
└────────────────────────────────────────────────────────────┘
Хост         : 127.0.0.1
Порт         : 6379
Статус       : Подключен к XenForo (config.php)

┌────────────────────────────────────────────────────────────┐
│ 📊 PHPMYADMIN
└────────────────────────────────────────────────────────────┘
URL          : http://${DOMAIN}/phpmyadmin
Пользователь : ${MYSQL_USER}
Пароль       : ${MYSQL_PASS}

┌────────────────────────────────────────────────────────────┐
│ 🌐 XENFORO
└────────────────────────────────────────────────────────────┘
URL          : http://${DOMAIN}
Admin User   : ${XENFORO_ADMIN_USER}
Admin Pass   : ${XENFORO_ADMIN_PASS}
Admin Email  : ${XENFORO_ADMIN_EMAIL}

┌────────────────────────────────────────────────────────────┐
│ 📁 FTP
└────────────────────────────────────────────────────────────┘
Хост         : ${PUBLIC_IP}
Порт         : 21
Пользователь : ${FTP_USER}
Пароль       : ${FTP_PASS}
Режим        : Passive
Passive ports: ${PASV_MIN}-${PASV_MAX}

┌────────────────────────────────────────────────────────────┐
│ ⚠️  ВАЖНО
└────────────────────────────────────────────────────────────┘
• Храните этот файл в безопасном месте.
• Не передавайте его третьим лицам.
• После первой установки смените все пароли.
• После установки XenForo удалите директорию /install/.
==============================================================
EOF

chmod 600 "$CREDENTIALS_FILE"

# ==========================================================
#  ФИНАЛЬНОЕ СООБЩЕНИЕ
# ==========================================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              ✅ УСТАНОВКА ЗАВЕРШЕНА                      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}🌐 САЙТ / XENFORO${NC}"
echo -e "   URL: http://${DOMAIN}"
echo ""
echo -e "${YELLOW}📊 PHPMYADMIN${NC}"
echo -e "   URL: http://${DOMAIN}/phpmyadmin"
echo ""
echo -e "${YELLOW}🗄️  MYSQL / MARIADB${NC}"
echo -e "   Порт: 3306"
echo -e "   База: ${MYSQL_DB}"
echo ""
echo -e "${YELLOW}🧠 REDIS${NC}"
echo -e "   Порт: 6379 (Используется для кэша XenForo)"
echo ""
echo -e "${YELLOW}📡 FTP${NC}"
echo -e "   Порт: 21"
echo -e "   Passive: ${PASV_MIN}-${PASV_MAX}"
echo ""
echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║                 🔐 ДАННЫЕ ДОСТУПА                        ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}🗄️  MYSQL / PHPMYADMIN${NC}"
echo -e "   ├─ Пользователь : ${MYSQL_USER}"
echo -e "   ├─ Пароль       : ${MYSQL_PASS}"
echo -e "   └─ База данных  : ${MYSQL_DB}"
echo ""
echo -e "${YELLOW}🌐 XENFORO ADMIN${NC}"
echo -e "   ├─ URL          : http://${DOMAIN}"
echo -e "   ├─ Пользователь : ${XENFORO_ADMIN_USER}"
echo -e "   ├─ Пароль       : ${XENFORO_ADMIN_PASS}"
echo -e "   └─ Email        : ${XENFORO_ADMIN_EMAIL}"
echo ""
echo -e "${YELLOW}📁 FTP${NC}"
echo -e "   ├─ Host         : ${PUBLIC_IP}"
echo -e "   ├─ Port         : 21"
echo -e "   ├─ User         : ${FTP_USER}"
echo -e "   ├─ Password     : ${FTP_PASS}"
echo -e "   └─ Mode         : Passive"
echo ""
echo -e "${YELLOW}💾 ФАЙЛ С ДАННЫМИ${NC}"
echo -e "   ${CREDENTIALS_FILE}"
echo ""
echo -e "${YELLOW}📝 ЕСЛИ CLI-УСТАНОВКА XENFORO НЕ ЗАВЕРШИЛАСЬ${NC}"
echo ""
echo -e "   ${GREEN}1.${NC} Откройте:"
echo -e "      http://${DOMAIN}/install/"
echo ""
echo -e "   ${GREEN}2.${NC} Откройте страницу в режиме ИНКОГНИТО."
echo ""
echo -e "   ${GREEN}3.${NC} Нажмите:"
echo -e "      ${YELLOW}Use these values${NC}"
echo ""
echo -e "   ${GREEN}4.${NC} Завершите установку XenForo."
echo ""
echo -e "   ${GREEN}5.${NC} После установки удалите:"
echo -e "      /install/"
echo ""
echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║                    ⚠️  ВНИМАНИЕ                           ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "   🔐 Все пароли сгенерированы автоматически."
echo -e "   💾 Данные сохранены в:"
echo -e "      ${CREDENTIALS_FILE}"
echo ""
echo -e "   📦 Скопируйте файл в безопасное место."
echo -e "   🔄 После установки смените пароли."
echo -e "   🗑️  Не оставляйте файл с паролями в доступном месте."
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}              🎉 ГОТОВО! УДАЧНОЙ РАБОТЫ!                  ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""

cat "$CREDENTIALS_FILE"
