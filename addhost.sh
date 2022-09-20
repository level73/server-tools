#!/bin/bash

#permissions
if [ "$(whoami)" != "root" ]; then
	echo "Root privileges are required to run this, please run with sudo."
	exit 2
fi

#configuration variables
current_directory="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)"
hosts_path="/etc/hosts"
vhosts_path="/etc/apache2/sites-available/"
vhost_blueprint="$current_directory/blueprints/vhost.blueprint.conf"
web_root="/var/www/"

#user input passed on CLI
site_url=0
relative_doc_root=0

while getopts ":u:d" o; do
	case "${o}" in
		u)
			site_url=${OPTARG}
			;;
		d)
			relative_doc_root=${OPTARG}
			;;
	esac
done

#run prompt if no args have been passed on
if [ $site_url == 0 ]; then
	read -p "Please enter the desired url: " site_url
fi
if [ $relative_doc_root == 0 ]; then
	read -p "Please enter the site path relative to the webroot: $web_root" relative_doc_root
fi

#make absolute path
absolute_doc_root=$web_root$relative_doc_root

#crete directory if it doesn't exist
if [ ! -d "$absolute_doc_root" ]; then
	#create dir
	`mkdir "$absolute_doc_root/"`
	#create public html dir or wordpress dir
	install_dir=0
	read -p "Is this a WordPress site? [Y/n]" yn
    case $yn in
      [Yy]* ) install_dir="wordpress";;
      [Nn]* ) install_dir="public_html";;
      * ) echo "Please answer yes or no.";;      
    esac
	echo "Installation directory is /${install_dir}/"
	

	#create logs dir
	`mkdir "$absolute_doc_root/logs"`

	`chown -R $SUDO_USER:staff "$absolute_doc_root/"`
	echo "Created directory $absolute_doc_root along with logs and public_html"

	#call wphost if site is a wordpress site
	if [ "$install_dir" = "wordpress" ]; then
		wp_dir="$absolute_doc_root/"
		echo "Wordpress dir is : $wp_dir"
		wphost "$wp_dir"
	else 
		#if NOT a wordpress site, create a /puclic_html dir inside abs doc root
		`mkdir "$absolute_doc_root/$install_dir"`
	fi

fi

echo "Absolute Doc Root is: $absolute_doc_root"

#update the vhost file
vhost=`cat "$vhost_blueprint"`
vhost=${vhost//@site_url@/$site_url}
vhost=${vhost//@site_docroot@/$absolute_doc_root}	
vhost=${vhost//@install_dir@/$install_dir}	


`touch $vhosts_path$site_url.conf`
echo "$vhost" > "$vhosts_path$site_url.conf"
echo "Updated the vhosts in the Apache Directory"

#update the hosts file
# SOLO SE LOCALE!! INSERT IF NOT LOCAL SITE.
	read -p "Is this a LOCAL site? [Y/n]" yn
    case $yn in
      [Yy]* ) echo 127.0.0.1	$site_url >> $hosts_path && echo "Updated the hosts file";;
      [Nn]* ) echo "Implement if not local..." && continue;;
      * ) echo "Please answer yes or no.";;      
    esac
	

#Enable and restart Apache
echo "Enabling new website..."
echo `a2ensite $site_url`

echo "Restarting Apache..."
echo `systemctl restart apache2`

#call "setssl" for enable SSL with CERTBOT
setssl "$site_url"

echo "Done"