# server-tools
Set of bash scripts to run basic setup for virtual hosts, applications and whatnot

## Installation
1. Clone the repository from Github the way you want

2. Navigate to the directory where you cloned the repo and add executable permission to "install.sh"

   `$ chmod +x install.sh`

3. Run installation script with sudo privileges

   `$ sudo ./install.sh`

## Usage
To create a virtual host for a generic website, and the relative directory in /var/www/, use:

```$ sudo addhost -t generic -u example.com -a www.example.com -d example.com```

## Wordpress
This small suite allows to set up a VHOST and automatically install a WordPress instance in the target directory.
To do so the tool requires [WP CLI](https://wordpress.org/cli/) to be available in the VPS.
Use:

```$ sudo addhost -t wordpress -u example.com -a www.example.com -d example.com```

## Loom73
Loom73 is the upcoming blueprint for PHP applications that we use in Level73.
To set up the infrastructure for it, use:

```$ sudo addhost -t loom73 -u example.com -a www.example.com -d example.com -o deploy```