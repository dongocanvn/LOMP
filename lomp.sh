#!/bin/bash

# Kiểm tra quyền root
if [ "$EUID" -ne 0 ]; then
    echo "Vui lòng chạy script với quyền root!"
    exit 1
fi

# Biến cấu hình
DOMAIN="yourdomain.com"
EMAIL="your.email@example.com"  # Email cho Let's Encrypt
DB_PASSWORD=$(openssl rand -base64 12)  # Mật khẩu ngẫu nhiên cho MariaDB
DB_USER="filerun_user"
DB_NAME="filerun"

# Cập nhật hệ thống
dnf update -y

# Cài đặt các công cụ cần thiết
dnf install -y wget unzip epel-release nano

# 1. Cài đặt OpenLiteSpeed
rpm -Uvh http://rpms.litespeedtech.com/centos/litespeed-repo-1.3-1.el9.noarch.rpm
dnf install -y openlitespeed
systemctl start lsws
systemctl enable lsws

# Mở port cho OpenLiteSpeed
firewall-cmd --permanent --add-port=8088/tcp
firewall-cmd --permanent --add-port=7080/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --reload

# Đặt mật khẩu WebAdmin
echo -e "admin\n123456\n123456" | /usr/local/lsws/admin/misc/admpass.sh

# 2. Cài đặt MariaDB 10.11
cat << EOF > /etc/yum.repos.d/MariaDB.repo
[mariadb]
name = MariaDB
baseurl = http://yum.mariadb.org/10.11/rhel9-amd64
module_hotfixes=1
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF
dnf install -y MariaDB-server MariaDB-client
systemctl start mariadb
systemctl enable mariadb

# Bảo mật MariaDB
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
mysql -u root -p"$DB_PASSWORD" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"$DB_PASSWORD" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -u root -p"$DB_PASSWORD" -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p"$DB_PASSWORD" -e "FLUSH PRIVILEGES;"

# Lưu thông tin đăng nhập MariaDB
echo "MariaDB Root Password: $DB_PASSWORD" > /root/db_credentials.txt

# 3. Cài đặt các phiên bản PHP
dnf install -y lsphp74 lsphp74-common lsphp74-mysqlnd lsphp74-gd lsphp74-process lsphp74-mbstring lsphp74-xml lsphp74-pdo lsphp74-imap lsphp74-soap lsphp74-bcmath lsphp74-zip
dnf install -y lsphp81 lsphp81-common lsphp81-mysqlnd lsphp81-gd lsphp81-process lsphp81-mbstring lsphp81-xml lsphp81-pdo lsphp81-imap lsphp81-soap lsphp81-bcmath lsphp81-zip
dnf install -y lsphp83 lsphp83-common lsphp83-mysqlnd lsphp83-gd lsphp83-process lsphp83-mbstring lsphp83-xml lsphp83-pdo lsphp83-imap lsphp83-soap lsphp83-bcmath lsphp83-zip
dnf install -y lsphp84 lsphp84-common lsphp84-mysqlnd lsphp84-gd lsphp84-process lsphp84-mbstring lsphp84-xml lsphp84-pdo lsphp84-imap lsphp84-soap lsphp84-bcmath lsphp84-zip

# Tối ưu PHP (OPcache và giới hạn)
for version in 74 81 83 84; do
    cat << EOF > /usr/local/lsws/lsphp${version}/etc/php.d/10-opcache.ini
zend_extension=opcache.so
opcache.enable=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.enable_cli=1
EOF
    sed -i 's/memory_limit = .*/memory_limit = 256M/' /usr/local/lsws/lsphp${version}/etc/php.ini
    sed -i 's/max_execution_time = .*/max_execution_time = 60/' /usr/local/lsws/lsphp${version}/etc/php.ini
    sed -i 's/upload_max_filesize = .*/upload_max_filesize = 100M/' /usr/local/lsws/lsphp${version}/etc/php.ini
    sed -i 's/post_max_size = .*/post_max_size = 100M/' /usr/local/lsws/lsphp${version}/etc/php.ini
    sed -i 's/max_input_vars = .*/max_input_vars = 2000/' /usr/local/lsws/lsphp${version}/etc/php.ini
done

# 4. Cài đặt phpMyAdmin
cd /usr/local/lsws/Example/html
wget https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-all-languages.zip
unzip phpMyAdmin-5.2.1-all-languages.zip
mv phpMyAdmin-5.2.1-all-languages phpmyadmin
cp phpmyadmin/config.sample.inc.php phpmyadmin/config.inc.php
BLOWFISH_SECRET=$(openssl rand -base64 32)
sed -i "s|\$cfg\['blowfish_secret'\] = .*|\$cfg['blowfish_secret'] = '$BLOWFISH_SECRET';|" phpmyadmin/config.inc.php
sed -i "s|\$cfg\['Servers'\]\[1\]\['host'\] = .*|\$cfg['Servers'][1]['host'] = 'localhost';|" phpmyadmin/config.inc.php
chown -R lsadm:lsadm phpmyadmin

# 5. Cài đặt FileRun
wget https://filerun.com/download-latest -O filerun.zip
unzip filerun.zip
mv filerun filerun
chown -R lsadm:lsadm filerun
mysql -u root -p"$DB_PASSWORD" -e "CREATE DATABASE $DB_NAME;"
mysql -u root -p"$DB_PASSWORD" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';"
mysql -u root -p"$DB_PASSWORD" -e "FLUSH PRIVILEGES;"
echo "FileRun Database: $DB_NAME" >> /root/db_credentials.txt
echo "FileRun User: $DB_USER" >> /root/db_credentials.txt
echo "FileRun Password: $DB_PASSWORD" >> /root/db_credentials.txt

# 6. Tạo Virtual Host cho domain
mkdir -p /var/www/$DOMAIN/html
chown -R lsadm:lsadm /var/www/$DOMAIN
echo "<?php phpinfo(); ?>" > /var/www/$DOMAIN/html/info.php
cat << EOF > /usr/local/lsws/conf/vhosts/$DOMAIN/vhconf.conf
docRoot                   /var/www/$DOMAIN/html
vhDomain                  $DOMAIN
vhAliases                 www.$DOMAIN
enableGzip                1
enableCache               1

index  {
  useServer               0
  indexFiles              index.php, index.html
}

expires  {
  enableExpires           1
  expiresByType           text/*=A31536000,application/javascript=A31536000,image/*=A31536000
}

errorlog /var/www/$DOMAIN/logs/error.log {
  logLevel                DEBUG
  rollingSize             10M
}

accesslog /var/www/$DOMAIN/logs/access.log {
  rollingSize             10M
  keepDays                30
}
EOF
mkdir -p /var/www/$DOMAIN/logs
chown -R lsadm:lsadm /var/www/$DOMAIN/logs
mkdir -p /usr/local/lsws/cache/$DOMAIN
chown -R lsadm:lsadm /usr/local/lsws/cache

# 7. Cài đặt SSL Let's Encrypt
dnf install -y certbot
certbot certonly --standalone -d $DOMAIN -d www.$DOMAIN --non-interactive --agree-tos --email $EMAIL

# Cấu hình SSL trong OpenLiteSpeed
cat << EOF > /usr/local/lsws/conf/httpd_config.conf
listener Default {
  address                 *:8088
  secure                  0
  map                     $DOMAIN $DOMAIN
}

listener SSL {
  address                 *:443
  secure                  1
  map                     $DOMAIN $DOMAIN
}

vhssl  {
  keyFile                 /etc/letsencrypt/live/$DOMAIN/privkey.pem
  certFile                /etc/letsencrypt/live/$DOMAIN/fullchain.pem
  certChain               1
  sslProtocol             24
}
EOF

# 8. Tối ưu hóa OpenLiteSpeed
sed -i 's/maxConnections.*$/maxConnections\t\t\t2000/' /usr/local/lsws/conf/httpd_config.conf
sed -i 's/maxSSLConnections.*$/maxSSLConnections\t\t2000/' /usr/local/lsws/conf/httpd_config.conf
sed -i 's/connTimeout.*$/connTimeout\t\t\t30/' /usr/local/lsws/conf/httpd_config.conf
sed -i 's/maxReqBodySize.*$/maxReqBodySize\t\t100M/' /usr/local/lsws/conf/httpd_config.conf
sed -i 's/useSendfile.*$/useSendfile\t\t\t1/' /usr/local/lsws/conf/httpd_config.conf
sed -i 's/fileETag.*$/fileETag\t\t\tNone/' /usr/local/lsws/conf/httpd_config.conf

# Tạo thư mục cache
mkdir -p /usr/local/lsws/cache
chown lsadm:lsadm /usr/local/lsws/cache

# Khởi động lại OpenLiteSpeed
/usr/local/lsws/bin/lswsctrl restart

# Thông báo hoàn tất
echo "Cài đặt hoàn tất! Kiểm tra thông tin sau:"
echo "1. WebAdmin: https://$(hostname -I | awk '{print $1}'):7080 (User: admin, Pass: 123456)"
echo "2. phpMyAdmin: http://$(hostname -I | awk '{print $1}'):8088/phpmyadmin"
echo "3. FileRun: http://$(hostname -I | awk '{print $1}'):8088/filerun (Cần cấu hình qua trình duyệt)"
echo "4. Virtual Host: /usr/local/lsws/conf/vhosts/$DOMAIN/vhconf.conf"
echo "5. Website: http://$DOMAIN:8088/info.php hoặc https://$DOMAIN/info.php"
echo "6. Thông tin MariaDB và FileRun được lưu tại: /root/db_credentials.txt"
echo "7. Cần trỏ DNS cho $DOMAIN về $(hostname -I | awk '{print $1}')"
echo "8. Cấu hình thêm trong WebAdmin để tối ưu chi tiết."
