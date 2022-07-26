# server-tools
Set of bash scripts to run basic setup for virtual hosts, applications and whatnot

# Installation
1. clone the repository from github the way you want

2. navigate to the directory where you cloned the repo and add executable permission to "install.sh"  

   `$ chmod +x install.sh`

3. run installation script with sudo privileges  

   `$ sudo ./install.sh`

#Config for MYSQL - use this command to store mysql password on your machine:

   `sudo mysql_config_editor set --login-path=client --host=localhost --user=root --password`
   
#then enter your password