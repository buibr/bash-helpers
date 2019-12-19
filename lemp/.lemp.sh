#   Create new user with root access
#---------------------------------------
sudo apt update
sudo apt upgrade
sudo apt update

#   Install Nginx
#---------------------------------------
sudo install nginx
sudo ufw enable
sudo ufw allow 'Nginx HTTP'
sudo ufw status

#   Install MySQL Server
#---------------------------------------
sudo apt install mysql-server
sudo mysql_secure_installation
sudo mysql -uroot < "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'Aa123@321';"
sudo mysql -uroot -pAa123@321 < "FLUSH PRIVILEGES;"


#   Install PHP-FPM
#---------------------------------------
sudo add-apt-repository universe
sudo apt install php-fpm php-mysql
