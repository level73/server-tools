#!/bin/bash

#makes sure user is root
if [$(whoami)!= "root"]; then
    echo "Please run the installation script with sudo privileges..."
    exit 1
fi

#Adds executable permission to addhost file, if exists, and copies it to /usr/local/bin
addhost_file= "./addhost.sh"
if [ -f "$addhost_file"]; then
    chmod +x $addhost_file
    
    #checks if there is an older version of addhost file in /usr/local/bin 
    if [ -f "/usr/local/bin/addhost"]; then
    echo "addhost file already exists..."
    echo "Do you want to remove it and install a new version?"
    select yn in "Yes" "No"
    case $yn in
    Yes ) rm -r /usr/local/bin/addhost;;
    No ) exit 1;;
    esac
    fi
    cp $addhost_file /usr/local/bin/addhost
    echo "Installation of addhost completed"
else
    echo "There is no addhost.sh file in your working directory, please add it"
    exit 1
fi
