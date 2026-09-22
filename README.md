mkdir -p temp && wget -O temp/install.sh https://raw.githubusercontent.com/RamzST-MC/web/master/web.sh && sed -i 's/\r$//' temp/install.sh && chmod +x temp/install.sh && bash ./temp/install.sh





sudo systemctl restart php8.4-fpm
sudo systemctl status php8.4-fpm
