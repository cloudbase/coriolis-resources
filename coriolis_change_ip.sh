#!/bin/bash
set -e

get_interface_ipv4 () {
    local IFACE=$1
    ip addr show $IFACE | sed -n 's/^\s*inet \([0-9.]*\)\/[0-9]*\s* brd [0-9.]*.*$/\1/p'
}

source /var/lib/coriolis/keystone_admin_rc

CONFIG_PATH=/var/lib/coriolis/coriolis.ini
OLD_IP=`crudini --get $CONFIG_PATH dhcp current_ip`
NEW_IP=$1

if [ -z "$OLD_IP" ]; then
    echo "OLD_IP not set"
    exit 1
fi

if [ -z "$NEW_IP" ]; then
    PUBLIC_IFACE=`crudini --get $CONFIG_PATH dhcp interface`
    if [ -z "$PUBLIC_IFACE" ]; then
        echo "Interface not set"
        exit 1
    fi

    NEW_IP=`get_interface_ipv4 $PUBLIC_IFACE`
    if [ -z "$NEW_IP" ]; then
        echo "Interface ip not set"
        exit 1
    fi
fi

if [ "$NEW_IP" == "$OLD_IP" ]; then
   echo "NEW_IP equals OLD_IP, no action needed"
   exit 0
fi

crudini --set /etc/barbican/barbican.conf DEFAULT host_href http://$NEW_IP:9311

L=`openstack endpoint list | grep $OLD_IP | awk '{print $2 " " $14}'`
if [ -z "$L" ]; then
    echo "Could not get endpoint list"
    exit 1
fi

IFS=$'\n'
for i in $L; do
    unset IFS
    read ID OLD_URL <<< $i
    NEW_URL=`echo "$OLD_URL" | sed 's/'$OLD_IP'/'$NEW_IP'/g'`
    echo openstack endpoint set $ID --url "$NEW_URL"
    openstack endpoint set $ID --url "$NEW_URL"
done

service barbican-worker restart
service apache2 restart

crudini --set $CONFIG_PATH dhcp current_ip $NEW_IP

