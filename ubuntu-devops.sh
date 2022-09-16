#!/usr/bin/env bash


# verify user identity for script activation
if [[ " $(id -Gn ) " == *" sudo "* ]]
then
    sudo ./$0
    exit 0
fi
if [[ $EUID -ne 0 ]]; then
    echo 'Error: root privileges are needed to run this script'
    exit 1
fi


# steps 2, 3, 4 - install Apache & mysql & phpMyAdmin
function ampInstall () {

        clear
        apt-get -y update

        # APACHE & MYSQL-SERVER need to be setup and running BEFORE installing PHPMYADMIN(that runs on it)
        apt-get -y install apache2 mysql-server

        # Automated, quiet & Non-wizard Installation of PHPMYADMIN
        DEBIAN_FRONTEND=noninteractive apt-get -y -q=5 install phpmyadmin

        # Non-wizard Configuration of PHPMYADMIN params
        dpkg-reconfigure --frontend=noninteractive phpmyadmin
}


# step 4.5 - install PHP
function phpInstall () {

        clear
        echo "Installing php"

        apt-get install -y lsb-release ca-certificates apt-transport-https software-properties-common -y
        apt-get install -y php
        apt-get install -y libapache2-mod-php php-mysql
        apt-get install -y libapache2-mod-php

        # for Appending the configuration details of phpmyadmin to the Apache machine configs
        echo "Include /etc/phpmyadmin/apache.conf" >> /etc/apache2/apache2.conf

        apt-get install -y sendmail

        # and have to Restart Apache services and defenitions
        systemctl reload apache2
}

# step 5 - WP
function wpSetup () {

        clear
        cp /etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/my.cnf
        systemctl restart mysql

        # read Site Parameters from User: DBName, DBUser, DBUserPass, hostname (ipaddress), siteName, siteEmail 
        echo "Creating database for wordpress"
        read -p "Please Enter the Database name: " wpdbname
        read -p "Please Enter DB User: " wpusername
        read -s -p "Please Enter DB User Password: " wpuserpass
        echo
        read -p "Please Enter your hostname (leave empty to use your external ip address): " wpsiteurl
        read -p "Please Enter your Site's Name: " wpsitename
        read -p "Please Enter your Site's eMail: " wpemail
        read -s -p "Please Enter wordpress admin password: " adminpass

        mysql -u root -e "CREATE DATABASE IF NOT EXISTS ${wpdbname}  /*\!40100 DEFAULT CHARACTER SET utf8 */;"
        mysql -u root -e "CREATE USER ${wpusername}@localhost IDENTIFIED BY '${wpuserpass}';"
        mysql -u root -e "GRANT ALL PRIVILEGES ON ${wpdbname}.* TO '${wpusername}'@'localhost';"
        mysql -u root -e "FLUSH PRIVILEGES;"

        if [ -z "$wpsiteurl" ]
        then
          wpsiteurl=$(curl --silent ifconfig.me)
        fi


        # Create WP site
        clear
        echo "============================================"
        echo "          WordPress Installation            "
        echo "============================================"

        # WP download CLI (preliminary)
        curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        php wp-cli.phar --info

        # set Write permissions to that file
        chmod +x wp-cli.phar
        mv -f wp-cli.phar /usr/local/bin/wp
        wp --info

        # If /var/www/${wpsitename} exists -> remove it
        #wpInstallDir=/var/www/"$wpsitename"
        wpInstallDir="/var/www/$wpsitename"
        if [ -d "$wpInstallDir" ]; then
          echo "$wpInstallDir does exist. removing directory... "
          rm -r -f "$wpInstallDir"
        fi


        # WP download (latest) & extract
        curl -O https://wordpress.org/latest.tar.gz
        tar -zxvf latest.tar.gz

        # move wordpress folder to parent dir
        mv wordpress "$wpInstallDir"

        # create uploads folder and set permissions
        mkdir "$wpInstallDir/wp-content/uploads"
        chmod 755 "$wpInstallDir/wp-content/uploads"

        # Ownership of main directory to hold all different WP Sites
        chown -R www-data:www-data "$wpInstallDir"
        chmod -R 755 "$wpInstallDir"
        echo
        echo "Installing wordpress..."

        # set Main Installation path
        wpconfig="$wpInstallDir/wp-config.php"

        # Install WP Core including wp-config.php rewrites
        wp cli cache clear --allow-root

        wp config create --path="$wpInstallDir" --dbname="$wpdbname" --dbuser="$wpusername" --dbpass="$wpuserpass" --config-file="$wpconfig" --allow-root
        if [ $? -ne 0 ] 
        then 
          echo "Failed to create wordpress config file at: $wpInstallDir."
          exit 1
        fi      

        wp core install --path="$wpInstallDir" --url="$wpsiteurl" --title="$wpsitename" --admin_user="admin" --admin_password="$adminpass" --admin_email="$wpemail" --allow-root
        if [ $? -ne 0 ] 
        then 
          echo "Failed to install wordpress in: $wpInstallDir."
          exit 1
        fi      

        # Install Plugins
        wp plugin install classic-editor --path="$wpInstallDir" --allow-root


        # set & limit resources (as requested)
        # create user.ini file in Website Folfer to Extent php.ini settings
        touch "$wpInstallDir/user.ini"

        printf "upload_max_filesize=128M \n" >> "$wpInstallDir/user.ini"
        printf "post_max_size=128M \n" >> "$wpInstallDir/user.ini"
        printf "memory_limit=256M \n" >> "$wpInstallDir/user.ini"


        # Create apache2 vhost
        rm /etc/apache2/sites-enabled/*
        cat <<EOF > "/etc/apache2/sites-available/$wpsitename.conf" 
        <VirtualHost *:80>
                ServerName $wpsitename
                ServerAdmin $wpemail
                DocumentRoot $wpInstallDir
                <Directory $wpInstallDir>
                        Options FollowSymLinks
                        AllowOverride Limit Options FileInfo
                        DirectoryIndex index.php
                        Require all granted
               </Directory>
               <Directory $wpInstallDir/wp-content>
                        Options FollowSymLinks
                        Require all granted
              </Directory>
                ErrorLog \${APACHE_LOG_DIR}/error.log
                CustomLog \${APACHE_LOG_DIR}/access.log combined
        </VirtualHost>
EOF

        a2ensite $wpsitename
        a2enmod rewrite
        systemctl reload apache2

        echo "<?php phpinfo(); ?>" > $wpInstallDir/phpinfo.php

        # get phpMyAdmin parameters from login page
        phpmuser=$( cat /etc/phpmyadmin/config-db.php | grep dbuser | sed -n 's/^.*'\''\([^'\'']*\)'\''.*$/\1/p' )
        phpmpass=$( cat /etc/phpmyadmin/config-db.php | grep dbpass | sed -n 's/^.*'\''\([^'\'']*\)'\''.*$/\1/p' )

        # end of wpSetup
        echo "==================================="
        echo "Installation of WP Site is complete"
        echo "==================================="
        echo
        echo
        echo "==================================="
        echo "You may now be able to use the following services"
        echo "PHPMYADMIN: http://$wpsiteurl/phpmyadmin"
        echo "    user:     $phpmuser"
        echo "    password: $phpmpass"
        echo
        echo "WORDPRESS: http://$wpsiteurl"
        echo "    user: admin"
        echo "    http://$wpsiteurl/wp-admin" 
        echo
        echo "PHPINFO: http://$wpsiteurl/phpinfo.php"
        echo "==================================="
}

# step 6 - PYTHON3
function pythonSetup () {
        echo "Installing Python3-pip please wait...\n"
        apt-get install python3-pip -y
        pip3 install flask
        pip3 install requests

        echo "Python3 environment is configured and ready."

}


# step 7 - NODEJS
function nodejsSetup () {
        apt-get install nodejs -y
        apt-get install npm -y
        echo node -v
        echo npm -v

}

function installSystemTools(){
        apt install net-tools -y
        apt-get install nmap -y
        apt-get install locate -y
        apt-get install htop -y
        apt-get install ufw -y
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 81/tcp
        updatedb
        apt-get install docker
        apt install openjdk-11-jre-headless
        apt-get install ansible -y
        apt-get install sshpass -y
        # Install Python Selenium

}

function createFlaskSite(){
touch testFlaskSite.py
cat << EOF > "~/testFlaskSite.py" 
        #!/bin/python

        from flask import Flask

        app = Flask(__name__))
        @app.route('/')
        Def index():
        return "Have a wonderfull day!"

        App.run(host="0.0.0.0", port=81)
EOF

        python3 testFlaskSite.py &

echo "Python Flask site is now running under port 81. Please edit  the testFlaskSite.py in your home directory!"
}


function installDocker(){
   #     apt-get install apt-transport-https ca-certificates curl software-properties-common
   #     curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
   #     add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable"
   #     apt-cache policy docker-ce
   #     apt-get install docker-ce
        
        echo "Installing Docker.io please wait..."
        apt-get install docker.io -y
        systemctl status docker
        echo "Docker is installed and ready."
}

function configureZSH(){
        bash -c "$(curl -fsSL https://raw.githubusercontent.com/matheusfillipe/dotfiles/master/install.sh)"
        bash -c "$(curl -fsSL https://raw.githubusercontent.com/matheusfillipe/dotfiles/master/update.sh)"
}


function installJenkins(){
        wget -q -O - https://pkg.jenkins.io/debian-stable/jenkins.io.key | sudo apt-key add -
        sudo sh -c 'echo deb http://pkg.jenkins.io/debian-stable binary/ > /etc/apt/sources.list.d/jenkins.list'
        sudo apt update
        sudo apt install jenkins -y
        systemctl start jenkins
        systemctl status jenkins
        ufw allow 8080
        ufw reload
}

function installMaven(){
        cat << EOF > "/root/.profile" 
        M2_HOME='/opt/apache-maven-3.6.3'
        PATH="$M2_HOME/bin:$PATH"
        export PATH
EOF
        wget https://mirrors.estointernet.in/apache/maven/maven-3/3.6.3/binaries/apache-maven-3.6.3-bin.tar.gz
        tar -xvf apache-maven-3.6.3-bin.tar.gz
        mv apache-maven-3.6.3 /opt/
        source ~/.profile   
        echo "Maven version 3.6.3 was installed successfuly."
        mvn --version
}        

function installPythonPackages(){
        pip3 install -U lxml
        pip3 install -U requests
        pip3 install selenium
        pip3 install camelot
        pip3 install camelot-py
        pip3 install pandas
        pip3 install seaborn
        pip3 install spacy
        pip3 install pdf2txt
        python3 -m spacy download en_core_web_sm
        pip3 install -U gensim
        pip3 install -U pillow
        pip3 install -U beautifulsoup4
        pip3 install python-jenkins
        pip3 install flask
        pip3 install flask-sqlalchemy
          
}

function setupPHPEnv(){
        apt-get install git -y 
        apt-get install php-debug -y
        apt-get install composer
        apt -y install php-7.4
        apt -y install php-fpm
        apt -y install software-properties-common
        apt-get install -y php7.4-cli php7.4-json php7.4-common php7.4-mysql php7.4-zip php7.4-gd php7.4-mbstring php7.4-curl php7.4-xml php7.4-bcmath
        apt-get install libapache2-mod-php5
        sudo apt-get install php-intl

}

function cleanAPT(){
        clear
        apt-get -y update
        apt-get autoremove -y
        apt-get autoclean -y
        apt-get clean
}
ampInstall
phpInstall
wpSetup
pythonSetup
nodejsSetup
installMaven
installSystemTools
createFlaskSite
installDocker
installJenkins
installMaven
installPythonPackages
setupPHPEnv
cleanAPT
configureZSH