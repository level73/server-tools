#!/bin/bash

#permissions
if [ "$(whoami)" != "root" ]; then
	echo "Root privileges are required to run this, please run with sudo."
	exit 2
fi

#!!! make sure to pass the site url as argument, WITHOUT "www." !!!

#command for activate ssl, using global variable "site_url"
echo "setting SSL certificate with certbot..."

read -p "Is this a Production site? (NO if DEVELOPMENT site) [Y/n]" yn
case $yn in
	[Yy]* ) echo "Setting certbot for BOTH www and plane url..." && 
	(certbot --apache -d $1 -d www.$1 && echo "Certbot setting completed.") || echo "Certbot setting FAILED..." ;;
	[Nn]* ) echo "Setting certbot for plane url ONLY..." && 
	(certbot --apache -d $1 && echo "Certbot setting completed.") || echo "Certbot setting FAILED...";;
	* ) echo "Please answer yes or no.";;      
	esac
