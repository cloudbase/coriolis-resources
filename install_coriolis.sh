#!/bin/bash
set -e

HOST_IP=10.14.0.186

export RABBIT_PASSWORD=Passw0rd
export ADMIN_PASSWORD=Passw0rd
export MYSQL_ROOT_PASSWORD=Passw0rd
export KEYSTONE_DB_PASSWORD=Passw0rd
export CORIOLIS_DB_PASSWORD=Passw0rd
export BARBICAN_PASSWORD=Passw0rd
export BARBICAN_DB_PASSWORD=Passw0rd
export CORIOLIS_PASSWORD=Passw0rd


add-apt-repository cloud-archive:liberty -y
apt-get update -y

apt-get install rabbitmq-server -y

rabbitmqctl add_user coriolis $RABBIT_PASSWORD
rabbitmqctl set_permissions -p / coriolis '.*' '.*' '.*'

apt-get install qemu-utils -y
apt-get install mysql-server -y

apt-get install keystone apache2 libapache2-mod-wsgi memcached python-memcache -y
apt-get install crudini -y

echo "manual" > /etc/init/keystone.override
service keystone stop

mysql -u root -p$MYSQL_ROOT_PASSWORD << EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' \
  IDENTIFIED BY '$KEYSTONE_DB_PASSWORD';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' \
  IDENTIFIED BY '$KEYSTONE_DB_PASSWORD';
EOF

rm -f /var/lib/keystone/keystone.db

crudini --set /etc/keystone/keystone.conf database connection "mysql+pymysql://keystone:$KEYSTONE_DB_PASSWORD@localhost/keystone"

ADMIN_TOKEN=`openssl rand -hex 10`
crudini --set /etc/keystone/keystone.conf DEFAULT admin_token $ADMIN_TOKEN
crudini --set /etc/keystone/keystone.conf memcache servers localhost:11211

crudini --set /etc/keystone/keystone.conf token provider uuid
crudini --set /etc/keystone/keystone.conf token driver memcache
crudini --set /etc/keystone/keystone.conf revoke driver sql

crudini --set /etc/keystone/keystone.conf DEFAULT verbose true

apt-get install python-pip -y
pip install pymysql
su -s /bin/sh -c "keystone-manage db_sync" keystone


cat <<'EOF' > /etc/apache2/sites-available/wsgi-keystone.conf
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /usr/bin/keystone-wsgi-public
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /usr/bin/keystone-wsgi-admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>
EOF

ln -s /etc/apache2/sites-available/wsgi-keystone.conf /etc/apache2/sites-enabled

service apache2 restart

# Config
export OS_TOKEN=$ADMIN_TOKEN
export OS_URL=http://localhost:35357/v3
export OS_IDENTITY_API_VERSION=3

apt-get install python-openstackclient -y
openstack service create --name keystone --description "OpenStack Identity" identity

openstack endpoint create --region RegionOne identity public http://localhost:5000/v2.0
openstack endpoint create --region RegionOne identity internal http://localhost:5000/v2.0
openstack endpoint create --region RegionOne identity admin http://localhost:35357/v2.0

openstack domain create default

openstack project create --domain default --description "Admin Project" admin
openstack user create --domain default --password $ADMIN_PASSWORD admin
openstack role create admin
openstack role add --project admin --user admin admin

openstack project create --domain default --description "Service Project" service

openstack project create --domain default --description "Demo Project" demo
openstack user create --domain default --password $ADMIN_PASSWORD demo
openstack role create user
openstack role add --project demo --user demo user


# Test
unset OS_TOKEN

#TODO add password
openstack --os-auth-url http://localhost:35357/v3 \
  --os-project-domain-id default --os-user-domain-id default \
  --os-project-name admin --os-username admin --os-auth-type password \
  token issue

openstack --os-auth-url http://localhost:5000/v3 \
  --os-project-domain-id default --os-user-domain-id default \
  --os-project-name demo --os-username demo --os-auth-type password \
  token issue

cat << EOF > ~/keystone_admin_rc
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$ADMIN_PASSWORD
export OS_AUTH_URL=http://localhost:35357/v3
export OS_IDENTITY_API_VERSION=3
EOF

source ~/keystone_admin_rc

# Coriolis

apt-get install python3-pip python3-eventlet libssl-dev libmysqlclient-dev -y

git clone https://github.com/cloudbase/pywinrm.git -b requests
pip3 install pywinrm/.
pip3 install mysqlclient

# Download coriolis here before installing
pip3 install coriolis/.

openstack service create --name coriolis --description "Cloud Migration as a Service" migration

ENDPOINT_URL="http://$HOST_IP:7667/v1/%(tenant_id)s"
openstack endpoint create --region RegionOne migration public $ENDPOINT_URL
openstack endpoint create --region RegionOne migration internal $ENDPOINT_URL
openstack endpoint create --region RegionOne migration admin $ENDPOINT_URL

openstack user create --domain default --password $CORIOLIS_PASSWORD coriolis
openstack role add --project service --user coriolis admin

useradd -r -s /bin/false coriolis
mkdir -p /etc/coriolis
chmod 700 /etc/coriolis

cp coriolis/etc/coriolis/coriolis.conf /etc/coriolis/
cp coriolis/etc/coriolis/api-paste.ini /etc/coriolis/

chown -R coriolis.coriolis /etc/coriolis

mkdir -p /var/log/coriolis
chown -R coriolis.coriolis /var/log/coriolis
chmod 700 /var/log/coriolis

crudini --set /etc/coriolis/coriolis.conf DEFAULT log_dir /var/log/coriolis
crudini --set /etc/coriolis/coriolis.conf DEFAULT verbose true
crudini --set /etc/coriolis/coriolis.conf DEFAULT messaging_transport_url rabbit://coriolis:$RABBIT_PASSWORD@127.0.0.1:5672/

crudini --set /etc/coriolis/coriolis.conf keystone_authtoken auth_url http://localhost:35357
crudini --set /etc/coriolis/coriolis.conf keystone_authtoken password $CORIOLIS_PASSWORD

crudini --set /etc/coriolis/coriolis.conf database connection mysql+pymysql://coriolis:$CORIOLIS_DB_PASSWORD@localhost/coriolis

mysql -u root -p$MYSQL_ROOT_PASSWORD << EOF
CREATE DATABASE coriolis;
GRANT ALL PRIVILEGES ON coriolis.* TO 'coriolis'@'localhost' \
  IDENTIFIED BY '$CORIOLIS_DB_PASSWORD';
GRANT ALL PRIVILEGES ON coriolis.* TO 'coriolis'@'%' \
  IDENTIFIED BY '$CORIOLIS_DB_PASSWORD';
EOF

# TODO: fix
su -s /bin/sh -c "python3 coriolis/cmd/db_sync.py"

if [ $(pidof systemd) ]; then
    cp coriolis/systemd/* /lib/systemd/system/
    systemctl enable coriolis-api.service
    systemctl enable coriolis-conductor.service
    systemctl enable coriolis-worker.service
    systemctl start coriolis-api.service
    systemctl start coriolis-conductor.service
    systemctl start coriolis-worker.service
else
    cp coriolis/debian/etc/init/* /etc/init
    service coriolis-api restart
    service coriolis-conductor restart
    service coriolis-worker restart
fi

# Barbican:
apt-get install barbican-api barbican-worker -y

openstack service create --name barbican --description "Barbican Service" key-manager

BARBICAN_ENDPOINT_URL="http://$HOST_IP:9311"
openstack endpoint create --region RegionOne key-manager public $BARBICAN_ENDPOINT_URL
openstack endpoint create --region RegionOne key-manager internal $BARBICAN_ENDPOINT_URL

openstack user create --domain default --password $BARBICAN_PASSWORD barbican
openstack role add --project service --user barbican admin

mysql -u root -p$MYSQL_ROOT_PASSWORD << EOF
CREATE DATABASE barbican;
GRANT ALL PRIVILEGES ON barbican.* TO 'barbican'@'localhost' \
  IDENTIFIED BY '$BARBICAN_DB_PASSWORD';
GRANT ALL PRIVILEGES ON barbican.* TO 'barbican'@'%' \
  IDENTIFIED BY '$BARBICAN_DB_PASSWORD';
EOF

rabbitmqctl add_user barbican $RABBIT_PASSWORD
rabbitmqctl set_permissions -p / barbican '.*' '.*' '.*'

crudini --set /etc/barbican/barbican.conf DEFAULT sql_connection mysql+pymysql://barbican:$BARBICAN_DB_PASSWORD@localhost/barbican

crudini --set /etc/barbican/barbican.conf DEFAULT rabbit_userid barbican
crudini --set /etc/barbican/barbican.conf DEFAULT rabbit_password $RABBIT_PASSWORD

crudini --set /etc/barbican/barbican.conf DEFAULT host_href http://$HOST_IP:9311

crudini --set /etc/barbican/barbican-api-paste.ini pipeline:barbican_api pipeline barbican-api-keystone

crudini --set /etc/barbican/barbican-api-paste.ini filter:keystone_authtoken auth_uri http://localhost:5000/v3
crudini --set /etc/barbican/barbican-api-paste.ini filter:keystone_authtoken auth_url http://localhost:35357/v3
crudini --set /etc/barbican/barbican-api-paste.ini filter:keystone_authtoken auth_plugin password
crudini --set /etc/barbican/barbican-api-paste.ini filter:keystone_authtoken username barbican
crudini --set /etc/barbican/barbican-api-paste.ini filter:keystone_authtoken password $BARBICAN_PASSWORD
crudini --set /etc/barbican/barbican-api-paste.ini filter:keystone_authtoken user_domain_name default
crudini --set /etc/barbican/barbican-api-paste.ini filter:keystone_authtoken project_name service
crudini --set /etc/barbican/barbican-api-paste.ini filter:keystone_authtoken project_domain_name default
crudini --set /etc/barbican/barbican-api-paste.ini filter:keystone_authtoken signing_dir /var/cache/barbican

crudini --set /etc/barbican/barbican.conf secrets broker rabbit://barbican:$RABBIT_PASSWORD@localhost

crudini --set /etc/barbican/vassals/barbican-api.ini uwsgi buffer-size 65535

chown -R barbican.barbican /etc/barbican
chmod 700 /etc/barbican

mkdir -p /var/cache/barbican
chown barbican.barbican /var/cache/barbican
chmod 700 /var/cache/barbican

#service barbican-api restart
service barbican-worker restart
service apache2 restart

# VMWare
wget https://dl.dropboxusercontent.com/u/9060190/VMware-vix-disklib-6.0.0-2498720.x86_64.tar.gz
tar zxvf VMware-vix-disklib-6.0.0-2498720.x86_64.tar.gz
cp vmware-vix-disklib-distrib/bin64/* /usr/bin
mkdir -p /usr/lib/vmware
cp -d vmware-vix-disklib-distrib/lib64/* /usr/lib/vmware
rm -rf vmware-vix-disklib-distrib/
rm VMware-vix-disklib-6.0.0-2498720.x86_64.tar.gz
