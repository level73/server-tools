#!/bin/bash

#1. Access mysql as root
#2. Create a database with a name
#3. Create user & password for mysql (query)
#4. Give privileges to new user for the new database
#5. Versarmi una birra

# revisiting architecture 12/10/2020
# create a db, asks for what user you want to add permission, if user exists >> add permission to db
# if user do not exists, create a new user and add permission to db

#makes sure user is root
if [ "$(whoami)" != 'root' ]; then
    echo "Please run the script with sudo privileges..."
    exit 1
fi

#checking if mysql is installed, if not >> exit
type mysql >/dev/null 2>&1 && echo "MySQL present." || echo "MySQL not present." || exit 1

#read -p "Type a new database name:" dbname
read -p "Type what USER to grant permission for \" ${dbname} \":" username
#read -p "Type a new password for ${username}:" password

#echo "${username} ${password} ${dbname}"


#1. access to MySQL as root
# Could be to run this line at the end with <<EOF
echo "Connecting to MYSQL as root..."
mysql -u root -p << EOF
\! echo "connected to MYSQL!!!"

#creates new database  (works)
#\! echo "Creating ${dbname} database..."   
#CREATE DATABASE IF NOT EXISTS ${dbname};

#checks for username, if not exists, creates it
IF (SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '${username}')) = 1 THEN
    \! echo "Username exists."

ELSE
    \! echo "Username \" ${username} \" NOT exists. Creating it for you."
    \! read -p "Type a password for ${username}:" password
    CREATE USER IF NOT EXISTS '${username}'@'localhost' IDENTIFIED BY '${password}';
        
END IF

#gives the user all privileges for new db
#GRANT ALL ON ${dbname}.* TO '${username}'@'localhost';
#flush privileges;


use mysql;
select user from user;
#SHOW DATABASES;

EOF
