#!/bin/bash

INSTALLER_URL="$1"
CLUSTER="$2"
INDEX="$3"
COUNT="$4"
LICENSE="$5"

if [ -r /etc/default/xcalar ]; then
    . /etc/default/xcalar
fi

XCE_HOME="${XCE_HOME:-/mnt/xcalar}"
XCE_CONFIG="${XCE_CONFIG:-/etc/xcalar/default.cfg}"
XCE_LICENSEDIR="${XCE_LICENSEDIR:-/etc/xcalar}"

SHARE=/srv/share

setenforce Permissive
sed -i -e 's/^SELINUX=enforcing.*$/SELINUX=permissive/g' /etc/selinux/config

yum update -y
yum install -y nfs-utils epel-release parted curl
yum install -y jq

# Download the installer as soon as we can
test -n "$INSTALLER_URL" && curl -sSL "$INSTALLER_URL" > installer.sh

# Node 0 will host NFS shared storage for the cluster
if [ "$INDEX" = 0 ]; then
    # On some Azure instances /mnt/resource comes premounted and unaligned
    if mountpoint -q /mnt/resource; then
        PART="$(findmnt -n /mnt/resource  | awk '{print $2}')"
        umount /mnt/resource
        DEV="${PART%[1-9]}"
        parted $DEV -s 'rm 1 mklabel gpt mkpart primary 1 -1'
        for retry in $(seq 5); do
            sleep 5
            mkfs.ext4 -L data -E lazy_itable_init=0,lazy_journal_init=0,discard $PART && break || echo "Retrying ..."
        done
        echo "LABEL=data     $SHARE   ext4    nobarrier,relatime  0   0" | tee -a /etc/fstab
        mkdir -p "$SHARE"
        mount "$SHARE"
    fi

    # Determine our CIDR by querying the metadata service
    curl -H Metadata:True "http://169.254.169.254/metadata/instance?api-version=2017-04-02&format=json" | jq . > metadata.json
    NETWORK="$(<metadata.json jq -r '.network.interface[].ipv4.subnet[].address')"
    MASK="$(<metadata.json jq -r '.network.interface[].ipv4.subnet[].prefix')"

    # Ensure NFS is running
    systemctl enable rpcbind
    systemctl enable nfs-server
    systemctl enable nfs-lock
    systemctl enable nfs-idmap
    systemctl start rpcbind
    systemctl start nfs-server
    systemctl start nfs-lock
    systemctl start nfs-idmap

    # Export the share to everyone in our CIDR block and mark it
    # as world r/w
    mkdir -p "${SHARE}/xcalar"
    chmod 0777 "${SHARE}/xcalar"
    echo "${SHARE}/xcalar      ${NETWORK}/${MASK}(rw,sync,no_root_squash,no_all_squash)" | tee /etc/exports
    systemctl restart nfs-server
    if firewall-cmd --state; then
        firewall-cmd --permanent --zone=public --add-service=nfs
        firewall-cmd --reload
    fi
fi

if [ -n "$INSTALLER_URL" ] && [ -f "installer.sh" ]; then
    if ! bash -x installer.sh --nostart; then
        echo >&2 "ERROR: Failed to run installer"
        exit 1
    fi
fi

DOMAIN="$(dnsdomainname)"
MEMBERS=()
for NODEID in $(seq 0 $((COUNT-1))); do
    MEMBERS+=("${CLUSTER}${NODEID}.${DOMAIN}")
done

/opt/xcalar/scripts/genConfig.sh /etc/xcalar/template.cfg - "${MEMBERS[@]}" | tee "$XCE_CONFIG"
if ! test -e "${XCE_LICENSEDIR}/XcalarLic.key"; then
    echo "$LICENSE" > "${XCE_LICENSEDIR}/XcalarLic.key"
fi

# Set up the mount for XcalarRoot
mkdir -p "$XCE_HOME"
echo "${CLUSTER}0:${SHARE}/xcalar   $XCE_HOME    nfs     defaults    0   0" | tee -a /etc/fstab

sed -r -i -e 's@^Constants.XcalarRootCompletePath=.*$@Constants.XcalarRootCompletePath='$XCE_HOME'@g' "$XCE_CONFIG"

mount "$XCE_HOME"

service xcalar start
