#!/bin/bash
set -e

sudo ip addr flush dev br-ex

SUBNET_ID=`neutron net-show -c subnets private | awk '{if (NR == 4) { print $4}}'`
neutron subnet-update $SUBNET_ID --dns_nameservers list=true 8.8.8.8 8.8.4.4

IMG_FILE=ubuntu-15.10-server-cloudimg-amd64-disk1.img

if [ ! -f $IMG_FILE ]; then
    wget https://cloud-images.ubuntu.com/releases/wily/release/$IMG_FILE
fi
glance image-create --property hypervisor_type=QEMU  --name "Ubuntu 15.10" --container-format bare --disk-format qcow2 --file $IMG_FILE

CORIOLIS_HOST_IP=10.14.0.179

openstack service create --name coriolis --description "Cloud Migration as a Service" migration

ENDPOINT_URL="http://$CORIOLIS_HOST_IP:7667/v1/%(tenant_id)s"
#openstack endpoint create --region RegionOne migration --publicurl $ENDPOINT_URL --internalurl $ENDPOINT_URL --adminurl $ENDPOINT_URL

openstack endpoint create --region RegionOne migration public $ENDPOINT_URL
openstack endpoint create --region RegionOne migration internal $ENDPOINT_URL
openstack endpoint create --region RegionOne migration admin $ENDPOINT_URL

openstack user create --password Passw0rd coriolis
openstack role add --project service --user coriolis admin

test -d ~/.ssh || mkdir ~/.ssh
nova keypair-add key1 > ~/.ssh/id_rsa_key1
chmod 600 ~/.ssh/id_rsa_key1

#barbican secret store --os-identity-api-version=2 --payload '{"host": "10.89.13.104", "port": 443, "username": "user@vsphere.local", "password": "Passw0rd", "allow_untrusted": true}'

