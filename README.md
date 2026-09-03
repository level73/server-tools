# server-tools

Set of bash scripts to provision a VPS with the environemnt to host a generic website or a PHP application. 

The suite sets up:
- a Virtual host 
- a dedicated PHP-FPM user
- a MySQL database (when needed)
- a WordPress instance (when needed)
- a Let's Encrypt SSL certificate. 

## Requirements
- PHP-FPM (v 8.4 is recommended)
- Apache webserver
- MySQL
- Certbot (Apache Plugin)
- WP CLI (if you want to use to deploy WP instances)

Installation of Certbot is intentionally not managed by server-tools because the recommended
package and installation method depend on the operating system and its release - as the other server side components.

Verify the Certbot installation with:

```bash
certbot --version
certbot plugins
```
The plugin list must include ```apache```.
Refer to the official Certbot instructions for the target operating system.

## Installation
1. Clone the repository from Github the way you want

2. Navigate to the directory where you cloned the repo and add executable permission to "install.sh"

   `$ chmod +x install.sh`

3. Run installation script with sudo privileges

   `$ sudo ./install.sh`

## Usage
The suite supports 3 types of setups:


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