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
APACHE_PORT=8080
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
echo -e "${GREEN} Nginx + Apache + PHP ${PHP_VER} + MySQL + phpMyAdmin + FTP + XenForo${NC}"
echo -e "${GREEN}============================================${NC}"

# ==========================================================
#  1. Исправление репозиториев
# ==========================================================
echo -e "\n${YELLOW}[1/12] Исправление репозиториев и очистка кэша...${NC}"
grep -rl "ua.archive.ubuntu.com" /etc/apt/ 2>/dev/null | xargs sed -i 's/ua\.archive\.ubuntu\.com/archive\.ubuntu\.com/g' 2>/dev/null || true
grep -rl "ua.ports.ubuntu.com" /etc/apt/ 2>/dev/null | xargs sed -i 's/ua\.ports\.ubuntu\.com/ports\.ubuntu\.com/g' 2>/dev/null || true
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
apt-get clean
rm -rf /var/lib/apt/lists/*
export DEBIAN_FRONTEND=noninteractive
apt-get update -y --fix-missing
apt-get --fix-broken install -y

# ==========================================================
#  2. Базовые пакеты
# ==========================================================
echo -e "\n${YELLOW}[2/12] Подготовка окружения...${NC}"
apt-get install -y software-properties-common curl gnupg2 ca-certificates lsb-release iptables iptables-persistent unzip wget git
add-apt-repository -y ppa:ondrej/php
apt-get update -y

# ==========================================================
#  3. Установка стека
# ==========================================================
echo -e "\n${YELLOW}[3/12] Установка Nginx, Apache2, PHP ${PHP_VER}-FPM...${NC}"
apt-get install -y \
    nginx \
    apache2 \
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
echo -e "${GREEN}PHP ${PHP_VER} успешно установлен.${NC}"
php${PHP_VER} -v | head -n 1

# ==========================================================
#  4. Настройка Apache (базовая)
# ==========================================================
echo -e "\n${YELLOW}[4/12] Настройка Apache (порт ${APACHE_PORT})...${NC}"
sed -i "s/^Listen 80$/Listen ${APACHE_PORT}/" /etc/apache2/ports.conf
mkdir -p "$WEB_ROOT"

# ==========================================================
#  5. Установка XenForo с GitHub
# ==========================================================
echo -e "\n${YELLOW}[5/12] Установка XenForo с GitHub...${NC}"
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
#  6. Установка MariaDB
# ==========================================================
echo -e "\n${YELLOW}[6/12] Установка MariaDB...${NC}"
apt-get install -y mariadb-server mariadb-client
systemctl start mariadb
systemctl enable mariadb
echo -e "${GREEN}MariaDB установлена и запущена.${NC}"

# ==========================================================
#  7. Создание базы данных для XenForo + ПРОВЕРКА ПОДКЛЮЧЕНИЯ
# ==========================================================
echo -e "\n${YELLOW}[7/12] Создание базы данных для XenForo...${NC}"
mysql -u root <<EOF
DROP USER IF EXISTS '${MYSQL_USER}'@'localhost';
DROP USER IF EXISTS '${MYSQL_USER}'@'%';
DROP DATABASE IF EXISTS ${MYSQL_DB};
CREATE DATABASE ${MYSQL_DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASS}';
CREATE USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASS}';
GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'localhost';
GRANT ALL PRIVILEGES ON ${MYSQL_DB}.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'%' WITH GRANT OPTION;
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
#  ИСПРАВЛЕНО: Создаём config.php в НУЖНОМ вам формате
# ==========================================================
echo -e "${YELLOW}Создание config.php в правильном формате...${NC}"
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
\$config['searchInnoDb'] = true;
XENCONFIG

chown www-data:www-data "$WEB_ROOT/src/config.php"
chmod 644 "$WEB_ROOT/src/config.php"

echo -e "${YELLOW}Проверка чтения config.php...${NC}"
if sudo -u www-data php -r "
require '${WEB_ROOT}/src/config.php';
if (empty(\$config['db']['username'])) {
    echo 'ERROR: username пустой!';
    exit(1);
}
echo 'OK: user=' . \$config['db']['username'] . ' db=' . \$config['db']['dbname'];
" 2>&1; then
    echo -e "${GREEN}✓ config.php корректен и читается${NC}"
else
    echo -e "${RED}✗ Ошибка в config.php!${NC}"
    cat "$WEB_ROOT/src/config.php"
    exit 1
fi

systemctl restart php${PHP_VER}-fpm

# ==========================================================
#  8. Настройка Nginx для XenForo (ЗДЕСЬ ЗАДАНЫ PHP_VALUE)
# ==========================================================
echo -e "\n${YELLOW}[8/12] Настройка Nginx для XenForo...${NC}"
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
    
    location ~* \.(jpg|jpeg|gif|png|css|js|ico|webp|tiff|ttf|svg|woff|woff2|eot|mp4|webm|ogg|mp3|wav|flac|pdf)\$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        log_not_found off;
        access_log off;
    }
    
    location ~* /(composer\.json|composer\.lock|phpunit\.xml|\.git) {
        deny all;
    }
    
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        # ✅ ПРАВИЛЬНЫЙ СПОСОБ задать лимиты PHP для Nginx + PHP-FPM
        fastcgi_param PHP_VALUE "upload_max_filesize=64M post_max_size=64M max_execution_time=300 max_input_time=300";
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }
    
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }
    
    location / {
        try_files \$uri \$uri/ @apache;
    }
    
    location @apache {
        proxy_pass http://127.0.0.1:${APACHE_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_CONF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/

# ==========================================================
#  9. Настройка Apache для XenForo (БЕЗ php_value)
# ==========================================================
echo -e "\n${YELLOW}[9/12] Настройка Apache для XenForo...${NC}"
cat <<APACHE_CONF > /etc/apache2/sites-available/${DOMAIN}.conf
<VirtualHost *:${APACHE_PORT}>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${WEB_ROOT}
    
    <Directory ${WEB_ROOT}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
        
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} -f [OR]
        RewriteCond %{REQUEST_FILENAME} -l [OR]
        RewriteCond %{REQUEST_FILENAME} -d
        RewriteRule ^.*$ - [NC,L]
        RewriteRule ^.*$ index.php [NC,L]
    </Directory>
    
    <Directory ${WEB_ROOT}/internal_data>
        Require all denied
    </Directory>
    
    <Directory ${WEB_ROOT}/src>
        Require all denied
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>
APACHE_CONF
a2enmod rewrite 2>/dev/null || true
a2dissite 000-default.conf 2>/dev/null || true
a2ensite "${DOMAIN}.conf"

# ==========================================================
#  10. vsftpd + пассивный режим
# ==========================================================
echo -e "\n${YELLOW}[10/12] Установка vsftpd с пассивным режимом...${NC}"
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
#  11. phpMyAdmin + iptables NAT + Firewall
# ==========================================================
echo -e "\n${YELLOW}[11/12] Установка phpMyAdmin и настройка Firewall...${NC}"
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
#  12. Перезапуск служб + ИНСТРУКЦИЯ ПО УСТАНОВКЕ
# ==========================================================
echo -e "\n${YELLOW}[12/12] Проверка и запуск служб...${NC}"
apache2ctl configtest
nginx -t
systemctl restart php${PHP_VER}-fpm apache2 nginx mariadb vsftpd
systemctl enable php${PHP_VER}-fpm apache2 nginx mariadb vsftpd

echo -e "\n${YELLOW}⚠ Автоустановка через CLI не поддерживается в этой сборке XenForo.${NC}"
echo -e "${YELLOW}Используйте веб-установщик (это займет 1 минуту):${NC}"
echo -e "${YELLOW}  1. Откройте в браузере: http://${DOMAIN}/install/ (рекомендуется режим инкогнито)${NC}"
echo -e "${YELLOW}  2. Нажмите 'Use these values' (данные БД уже подставлены из config.php)${NC}"
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
┌────────────────────────────────────────────────────────────┐
│ 🗄️  MYSQL
└────────────────────────────────────────────────────────────┘
Хост         : localhost
Порт         : 3306
База данных  : ${MYSQL_DB}
Пользователь : ${MYSQL_USER}
Пароль       : ${MYSQL_PASS}
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
echo -e "${YELLOW}🗄️  MYSQL${NC}"
echo -e "   Порт: 3306"
echo -e "   База: ${MYSQL_DB}"
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
echo -e "${YELLOW}⚙️  НАСТРОЙКИ FTP-КЛИЕНТА${NC}"
echo ""
echo -e "   Локальное подключение:"
echo -e "   ├─ Host: ${LOCAL_IP}"
echo -e "   └─ Port: 21"
echo ""
echo -e "   Внешнее подключение:"
echo -e "   ├─ Host: ${PUBLIC_IP}"
echo -e "   └─ Port: 21"
echo ""
echo -e "   ├─ User: ${FTP_USER}"
echo -e "   ├─ Pass: ${FTP_PASS}"
echo -e "   └─ Mode: Passive"
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
sudo apt remove php8.5-cli
sudo apt autoremove
cat "$CREDENTIALS_FILE"
