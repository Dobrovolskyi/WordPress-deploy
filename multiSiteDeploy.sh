#!/bin/bash

### Getting quantity of 
SITES_COUNT=$(cat ./config.json | jq ".sites | length");

i=0
while [ $i -lt $SITES_COUNT ]
do
    ### PARSING CONFIG
    SITENAME=$(cat ./config.json | jq -r ".sites[$i].sitename");
    SITEDIR=$(cat ./config.json | jq -r ".sites[$i].siteroot_dir");
    DB_NAME=$(cat ./config.json | jq -r ".sites[$i].db.name");
    DB_USER=$(cat ./config.json | jq -r ".sites[$i].db.username");
    DB_PASS=$(cat ./config.json | jq -r ".sites[$i].db.password");

    ADMIN_EMAIL=$(cat ./config.json | jq -r ".sites[$i].siteadmin");

    REQUREMENTS=$(cat ./config.json | jq -r ".sites[$i].requirements[]");

    BKP_RETANTION=$(cat ./config.json | jq ".sites[$i].backup.retention");
    BKP_PERIODICITY=$(cat ./config.json | jq -r ".sites[$i].backup.periodicity");
    
    #===================================================================================
    ### CHECKING REQUIREMENTS
    for PACKAGE in $REQUREMENTS
    do
    echo "Ensuring $PACKAGE is installed"
    dpkg -l | grep -qw $PACKAGE || sudo apt -y install $PACKAGE
    echo "done!"
    done

    #===================================================================================
    ### INSTALLING WORDPRESS
    wget -c http://wordpress.org/latest.tar.gz
    tar -xzvf latest.tar.gz -C $SITEDIR

    mv -v /var/www/html/wordpress $SITEDIR/$SITENAME
    rm /var/www/html/index.html

    sudo chown -R www-data:www-data $SITEDIR/$SITENAME
    sudo chmod -R 755 $SITEDIR/$SITENAME

    #===================================================================================
    ### CONFIGURING WebServer
    systemctl enable --now apache2
    ufw allow 80/tcp

    # Creating Virtual Host rule file
    echo "
        <VirtualHost *:80>
        ServerAdmin ${ADMIN_EMAIL-'webmaster@localhost'}
        ServerName $SITENAME
        DocumentRoot $SITEDIR
        <Directory $SITEDIR/>
            Options Indexes FollowSymLinks
            AllowOverride all
        </Directory>
        </VirtualHost>" > "/etc/apache2/sites-available/$SITENAME.conf"

    # Creating an IP address mapping
    sed -i "1s/^/127.0.0.1 $SITENAME\n/" /etc/hosts

    # Enabling the site
    a2ensite $SITENAME
    service apache2 reload

    #===================================================================================
    ### CREATING DATABASE

    sudo mysql -u root -e "CREATE DATABASE $DB_NAME;"

    sudo mysql -u root -e "CREATE USER $DB_USER@localhost IDENTIFIED BY '$DB_PASS';"
    sudo mysql -u root -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO $DB_USER@localhost;"

    sudo mysql -u root -e "exit"

    #===================================================================================
    ### SETTING BACKUP PARAMETERS

    # Creating Backp script
    mkdir "$SITEDIR/backups"

    cat >$SITEDIR/backups/backup-$SITENAME.sh <<'EOT'
# Retantion period control
find $BACKUP_DIR -maxdepth 1 -mtime $BKP_RETANTION*24 -type f -exec rm -rv {} \;

# Set the date format, filename and the directories where your backup files will be placed and which directory will be archived.
NOW=$(date +"%Y-%m-%d-%H%M")
FILE="$SITENAME.$NOW.tar"
BACKUP_DIR="$SITEDIR/backups"
WWW_DIR="$SITEDIR/$SITENAME"

# Tar transforms for better archive structure.
WWW_TRANSFORM="s,^$SITEDIR/$SITENAME,www,"
DB_TRANSFORM="s,^$BACKUP_DIR,database,"

# Create the archive and the MySQL dump
tar -cvf $BACKUP_DIR/$FILE --transform $WWW_TRANSFORM $WWW_DIR
mysqldump -u$DB_USER -p$DB_PASS -$DB_NAME > "$BACKUP_DIR/$DB_NAME.$NOW.sql"

# Append the dump to the archive, remove the dump and compress the whole archive.
tar --append --file=$BACKUP_DIR/$FILE --transform $DB_TRANSFORM "$BACKUP_DIR/$DB_NAME.$NOW.sql"
rm "$BACKUP_DIR/$DB_NAME.$NOW.sql"
gzip -9 $BACKUP_DIR/$FILE
EOT

    # Setting Cron Job for Backup Periodicity
    "$BKP_PERIODICITY backup-$SITENAME.sh" | crontab -

    i=$(($i+1))
done