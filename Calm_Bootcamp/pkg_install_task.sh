#!/bin/bash
set -ex

#sudo yum update -y
sudo yum -y install epel-release
sudo setenforce 0
sudo sed -i 's/enforcing/disabled/g' /etc/selinux/config /etc/selinux/config
sudo systemctl stop firewalld || true
sudo systemctl disable firewalld || true
sudo rpm -Uvh https://mirror.webtatic.com/yum/el7/webtatic-release.rpm
sudo yum update -y
sudo yum install -y nginx php git unzip wget php-fpm

sudo mkdir -p /var/www/laravel
echo "server {
 listen 80 default_server;
 listen [::]:80 default_server ipv6only=on;
root /var/www/laravel/public/;
 index index.php index.html index.htm;
location / {
 try_files \$uri \$uri/ /index.php?\$query_string;
 }
 # pass the PHP scripts to FastCGI server listening on /var/run/php5-fpm.sock
 location ~ \.php$ {
 try_files \$uri /index.php =404;
 fastcgi_split_path_info ^(.+\.php)(/.+)\$;
 fastcgi_pass 127.0.0.1:9000;
 fastcgi_index index.php;
 fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
 include fastcgi_params;
 }
}" | sudo tee /etc/nginx/conf.d/laravel.conf
sudo sed -i 's/80 default_server/80/g' /etc/nginx/nginx.conf
if `grep "cgi.fix_pathinfo" /etc/php.ini` ; then
 sudo sed -i 's/cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php.ini
else
 sudo sed -i 's/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/' /etc/php.ini
fi

sudo systemctl enable php-fpm
sudo systemctl enable nginx
sudo systemctl restart php-fpm
sudo chown -R nginx:nginx /var/www/laravel
sudo chmod -R 777 /var/www/laravel/
sudo mkdir /var/www/laravel/public
sudo wget -O /var/www/laravel/public/index.html https://raw.githubusercontent.com/bmp-ntnx/prep/master/index.html
sudo systemctl restart nginx
