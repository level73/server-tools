#!/bin/bash

#1. Access mysql as root
#2. Create a database with a name
#3. Create user & password for mysql (query)
#4. Give privileges to new user for the new database
#5. Versarmi una birra

# revisiting architecture 12/10/2020
# create a db, asks for what user you want to add permission, if user exists >> add permission to db
# if user do not exists, create a new user and add permission to db

#rev arch 13/10/2020
#previuous revs are tedious, now focusing on using sql querys from bash 


#makes sure user is root (ok!)
if [ "$(whoami)" != 'root' ]; then
    echo "Please run the script with sudo privileges..."
    exit 1
fi

#quitting function (ok!)
quitting() {
    echo "MySQL not present." && exit 1;
}

#checking if mysql is installed, if not >> exit (ok!)
type mysql >/dev/null 2>&1 && echo "MySQL present." || quitting

#asks for db name and username (ok!)
read -p "Type a new database name:" dbname
read -p "Type what USER to grant permission for \" ${dbname} \":" username


#string queries (ok!)
create_db_query="CREATE DATABASE IF NOT EXISTS ${dbname}; "
create_user_query="CREATE USER '${username}'@'localhost' IDENTIFIED BY '${password}'; "
grant_perm_query="GRANT ALL ON ${dbname}.* TO '${username}'@'localhost'; flush privileges; "
result_query="USE mysql; SELECT user FROM user; SHOW DATABASES; "

#checks if user exists (ok!)
echo "Checking if user exists, connecting to mysql as root..."
user_exists=$(mysql -u root -p -se " SELECT EXISTS(SELECT 1 FROM mysql.user WHERE user = '$username'); ")

#debugger
#echo ${user_exists}


#query constructor if user exists or not (ok!)
if [ ${user_exists} != 1 ]; then
    read -p "User ${username} NOT exists, do you want to create it? [Y/n]" yn
    case $yn in
      [Yy]* ) read -p "Type a password for \"${username}\":" password && query="$create_db_query$create_user_query$grant_perm_query$result_query";;
      [Nn]* ) echo "Exiting process..." && exit 1;;
      * ) echo "Please answer yes or no.";;      
      esac
else 
    query="$create_db_query$grant_perm_query$result_query"
fi

#debugger
#echo ${query}

#call query (ok!)
echo "Login to mysql as root:"
mysql -u root -p -e "${query}"

echo "Operation Completed."


