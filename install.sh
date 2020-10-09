#!/bin/bash

#makes sure user is root
if [ "$(whoami)" != 'root' ]; then
    echo "Please run the installation script with sudo privileges..."
    exit 1
fi

#Adds executable permission to addhost file, if exists, and copies it to /usr/local/bin

if [ -e "addhost.sh" ]; then
    chmod +x addhost.sh

    #checks if there is an older version of addhost file in /usr/local/bin 
    if [ -e "/usr/local/bin/addhost" ]; then
    echo "addhost file already exists..."
    read -p "Do you want to remove it and install a new version? [Y/n]:" yn
      case $yn in
      [Yy]* ) rm -r /usr/local/bin/addhost && echo "older addhost removed" && cp addhost.sh /usr/local/bin/addhost && echo "new addhost file added";;
      [Nn]* ) echo "Installation abort, exiting..." && exit 1;;
      * ) echo "Please answer yes or no.";;      
      esac
    else 
    cp addhost.sh /usr/local/bin/addhost && echo "addhost file added"
    fi
else
    echo "There is no addhost.sh file in your working directory, please add it"
    exit 1
fi
if [ -e "/usr/local/bin/addhost" ]; then
    echo "Installation completed."
else
    echo "Failed Installing..."
fi
