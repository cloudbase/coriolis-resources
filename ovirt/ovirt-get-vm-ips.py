# Copyright 2021 Cloudbase Solutions Srl
# All Rights Reserved.

import argparse
import copy
import logging
import uuid
import sys

import ovirtsdk4


LOG = logging.getLogger(__name__)


def setup_logging():
    LOG.setLevel(logging.DEBUG)
    h = logging.StreamHandler(stream=sys.stdout)
    f = logging.Formatter("%(levelname)s - %(message)s")
    h.setFormatter(f)
    LOG.addHandler(h)


def get_connection_builder(connection_info):
    connection_info = copy.deepcopy(connection_info)
    insecure = connection_info.pop('allow_untrusted', False)
    return ovirtsdk4.ConnectionBuilder(
        insecure=insecure,
        # NOTE: most of the debug output of the SDK are low-level
        # request/reply dumps which aren't too helpful:
        debug=False,
        log=LOG,
        **connection_info)


def get_vm(vms_service, vm_id):
    vm = vms_service.list(search="id=%s" % vm_id)
    return vm[0]


def get_vm_nics(conn, vm):
    return conn.follow_link(vm.nics)


def get_vm_addresses(nics):
    addresses = []
    for nic in nics:
        rps = nic.reported_devices
        if rps:
            for rp in rps:
                ips = rp.ips
                if ips:
                    for ip in ips:
                        addr = ip.address
                        if addr:
                            addresses.append(addr)
    return addresses


def get_vm_main_address(nics):
    ip_address = None
    for nic in nics:
        rps = nic.reported_devices
        if rps:
            for rp in rps:
                ips = rp.ips
                if ips:
                    for ip in ips:
                        addr = ip.address
                        if addr:
                            ip_address = addr
                            break
                if ip_address:
                    break
        if ip_address:
            break
    return ip_address


def main():
    setup_logging()
    parser = argparse.ArgumentParser(description="oVirt VM IP Address fetcher")
    parser.add_argument("vm_id", type=str, help="The ID of the VM")
    parser.add_argument("--url", type=str, help="oVirt API endpoint URL")
    parser.add_argument("--username", type=str,
                        help="oVirt API Username in the form of "
                             "username@domain")
    parser.add_argument("--password", type=str,
                        help="oVirt API password for provided username")
    parser.add_argument("--allow-untrusted",
                        default=False, action="store_true",
                        help="Whether or not certificate verification should "
                             "be skipped in case it was pointed to an HTTPS "
                             "oVirt endpoint. Internal default is False.")
    args = parser.parse_args()
    vm_id = args.vm_id
    try:
        vm_id = str(uuid.UUID(vm_id, version=4))
    except ValueError:
        raise Exception("Invalid UUID passed")

    conn_info = {
        "url": args.url,
        "username": args.username,
        "password": args.password,
        "allow_untrusted": args.allow_untrusted
    }
    conn_builder = get_connection_builder(conn_info)
    with conn_builder.build() as conn:
        vms = conn.system_service().vms_service()
        vm = get_vm(vms, vm_id)
        vm_nics = get_vm_nics(conn, vm)
        vm_primary_addr = get_vm_main_address(vm_nics)
        vm_addresses = get_vm_addresses(vm_nics)

        if vm_primary_addr:
            LOG.info("Primary IP address for VM %s: %s" % (
                vm_id, vm_primary_addr))
        else:
            LOG.warning("No primary IP found for VM '%s'" % vm_id)

        LOG.info("IP addresses for VM '%s': %s" % (vm_id, vm_addresses))


if __name__ == "__main__":
    main()
