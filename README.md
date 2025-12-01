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

# MySQL Monitor
A simple script to check if MySQL is running, and to restart it if needed. 
1. change permissions with 
`sudo chmod +x mysql_monitor.sh` to make the script executable
2. Add to crontab with `sudo crontab -e`
3. Paste to crontab: `* * * * * {PATH_TO_SCRIPT}/mysql_monitor.sh > /dev/null 2>&1`
4. Save and exit (`CTRL+X`, `Y`, `ENTER`)