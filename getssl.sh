#Script that install an ssl certificate using Let's Encrypt and CertBot


#makes sure user is root
if [ "$(whoami)" != 'root' ]; then
    echo "Please run the script with sudo privileges..."
    exit 1
fi

#Installing and refreshing snap
snap_install() {

    echo "Installing snap package manager."
    (sudo snap install core; sudo snap refresh core && echo "snap installed.") || (echo "snap not installed... exiting" && exit 1)
}

#remove other CertBot package 
certbot_exists() {

    echo "Checking if another CertBot package exists and removing it... "
    (sudo apt-get remove certbot && echo "certbot package removed.") || (echo "failed removing certbot...exiting" && exit 1)
}

#install certbot with snap
install_certbot() {
    echo "installing certbot..."
    (sudo snap install --classic certbot && echo "certbot installed.") || (echo "failed installing certbot, exiting..." && exit 1)
}

#prepare certbot command
prepare_certbot() {
    echo "Preparing certbot command..."
    (sudo ln -s /snap/bin/certbot /usr/bin/certbot && echo "certbot command prepared.") || (echo "certbot command not prepared, exiting..." && exit 1)
}


#run certbot and choose for an automatic or manual config
run_certbot () {

    
}


