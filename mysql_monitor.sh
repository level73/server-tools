#!/bin/bash

#Check DBMS is running
sudo systemctl status mysql > /dev/null 2>&1

#If MySQL is stuck restart
if [$? != 0]; then
    echo -e "MySQL was down. Restarting...\n"
    sudo systemctl restart mysql
else
  echo -e "MySQL was running, all good. \n"
fi
