# This script will add a virtual host with wordpress to your apache server

#1- download latest wordpress zip file    >>>  LOCATION?? == /var/www/wordpress/
#2- unzip wordpress at same level of public html dir
#3- remove zip file if unzipping went ok
# change permission to wordpress dit with " chown -r www-data:www-data wordpress " command
#4- create virtual host for wordpress dir
#5- create db with setmysql.sh

#makes sure user is root
if [ "$(whoami)" != 'root' ]; then
    echo "Please run the script with sudo privileges..."
    exit 1
fi

#quitting function (ok!)
quitting() {
    echo "${program} not present." && exit 1;
}
#checking if php is installed, if not >> exit 
program="PHP"
type php >/dev/null 2>&1 && echo "PHP present." || quitting

#checking if mysql is installed, if not >> exit 
program="MySQL"
type mysql >/dev/null 2>&1 && echo "MySQL present." || quitting

#create vhost for wordpress dir calling addhost.sh
create_host() {
    echo "Begin creating a virtual host..."
    addhost
}

#Download && Unzip && Delete wp latest.zip 
#NOTE: unzip process will create "wordpress" dir
dur_latestzip() {
    echo "Downloading WordPress latest version..."
    (wget -nd https://wordpress.org/latest.zip -P /var/www/wordpress/ && echo "latest.zip download complete." || echo "latest.zip download failed.") && (unzip latest.zip && echo "Unzipping complete." || echo "Unzipping failed.") && (rm -r latest.zip && echo "zip file deleted." || echo "removing zip file failed.") 
}
#change owner for wordpress dir
change_owner() {
    echo "Changing owner to wordpress dir..."
    chown -r www-data:www-data var/www/wordpress
}

#create db calling setmysql.sh
create_db() {
    echo "Begin setting MySQL database for wordpress..."
    setmysql
}

#call all functions

(create_host && echo "Virtual Host Created." || echo "virtual host FAILED...") && (dur_latestzip && echo "WP download completed." || echo "WP download FAILED.") && (change_owner && echo "Owner changed." || echo "changing owner FAILED.") && (create_db && echo "MySQL db created." || echo "data base creation FAILED.")