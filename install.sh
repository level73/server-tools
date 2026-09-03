#!/bin/bash

#makes sure user is root
if [ "$(whoami)" != 'root' ]; then
    echo "Please run the installation script with sudo privileges..."
    exit 1
fi


updater() {
    #checks if there is an older version of the script file in /usr/local/bin 
    if [ -e "/usr/local/bin/${1%.sh}" ]; then
    echo "${1%.sh} file already exists..."
    read -p "Do you want to remove it and install a new version? [Y/n]:" yn
      case $yn in
      [Yy]* ) rm -r /usr/local/bin/${1%.sh} && echo "older ${1%.sh} removed" && cp $1 /usr/local/bin/${1%.sh} && echo "new ${1%.sh} file added";;
      [Nn]* ) echo "Installation of ${1%.sh} abort..." ;;
      * ) echo "Please answer yes or no.";;      
      esac
    else 
    cp $1 /usr/local/bin/${1%.sh} && echo "${1%.sh} file added"
    fi
}

installer() {
    #check if script is in working dir, than install/update it 
    if [ -e $1 ]; then
        chmod +x $1
        updater $1
    else
    echo "There is no $1 file in your working directory, please add it"
    exit 1
    fi
    if [ -e "/usr/local/bin/${1%.sh}" ]; then
        echo "Installation of ${1%.sh} completed."
    else
        echo "Failed Installing ${1%.sh}..."
    fi
}


#array list of installation programs. Please insert a new script here to be installed
#remove suffix of element echo ${i%.sh} 
scripts=('addhost.sh' 'wphost.sh' 'setmysql.sh' 'setssl.sh')


#call installer for every script in array
for i in "${scripts[@]}"; do 
    installer $i
done 

#debug, print exec path of scripts
for i in "${scripts[@]}"; do 
    which ${i%.sh}
done 


#Blueprints dir installation dir
if [ -e "/usr/local/bin/blueprints" ]; then
    echo "Blueprints folder is present."
    read -p "Do you want to remove it and install a new version? [Y/n]:" yn
      case $yn in
      [Yy]* ) rm -r /usr/local/bin/blueprints && echo "older blueprints dir removed" && cp -r blueprints/ /usr/local/bin/blueprints && echo "new Blueprints folder added.";;
      [Nn]* ) echo "Installation of blueprints dir abort..." ;;
      * ) echo "Please answer yes or no.";;      
      esac
else
    cp -r blueprints/ /usr/local/bin/blueprints && echo "Blueprints folder added."
fi