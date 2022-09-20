#!/bin/bash

#permissions
if [ "$(whoami)" != "root" ]; then
	echo "Root privileges are required to run this, please run with sudo."
	exit 2
fi

#command for activate ssl, using global variable "site_url"
echo "setting SSL certificate with certbot..."

(systemctl `certbot --apache -d $1` && echo "Certbot setting completed.") || echo "Certbot setting FAILED..." 