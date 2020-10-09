#!/bin/bash

#1. Access mysql as root
#2. Create a database with a name
#3. Create user & password for mysql (query)
#4. Give privileges to new user for the new database
#5. Versarmi una birra

#makes sure user is root
if [ "$(whoami)" != 'root' ]; then
    echo "Please run the script with sudo privileges..."
    exit 1
fi

#checking if mysql is installed, if not >> exit
type mysql >/dev/null 2>&1 && echo "MySQL present." || echo "MySQL not present." exit 1

read -p "Type a name for the new user:" username
read -p "Type a new password for ${username}:" password
read -p "Type a new database name:" dbname
#echo "${username} ${password} ${dbname}"


#1. access to MySQL as root
# Could be to run this line at the end with <<EOF
mysql -u root -p || exit 1

#2. creates new database 
CREATE DATABASE ${dbname};

#create new user
CREATE USER \'${username}\'@\'localhost\' IDENTIFIED BY \'${password}\';

#4. gives the new user all privileges for new db
GRANT ALL ON ${dbname}.* TO \'${username}\'@\'localhost\';
flush privileges;


