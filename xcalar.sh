#!/bin/bash

INSTALLER_URL="$1"
CLUSTER="$2"
INDEX="$3"
COUNT="$4"

XLRROOT=/mnt/xcalar
DOMAIN="$(dnsdomainname)"

setenforce Permissive
sed -i -e 's/^SELINUX=enforcing.*$/SELINUX=permissive/g' /etc/selinux/config

yum update -y
yum install -y nfs-utils epel-release parted
yum install -y jq



if mountpoint -q /mnt/resource; then
    PART="$(findmnt -n /mnt/resource  | awk '{print $2}')"
    umount /mnt/resource
    DEV="${PART%[1-9]}"
    parted $DEV -s 'rm 1 mklabel gpt mkpart primary 1 -1'
    for retry in $(seq 5); do
        sleep 5
        mkfs.ext4 -L data -E lazy_itable_init=0,lazy_journal_init=0,discard $PART && break
    done
    UUID="$(blkid $PART | awk '{print $2}')"
    echo "LABEL=data     /mnt/data   ext4    nobarrier,relatime  0   0" | tee -a /etc/fstab
    mkdir -p /mnt/data
    mount /mnt/data
fi

curl -H Metadata:True "http://169.254.169.254/metadata/instance?api-version=2017-04-02&format=json" | jq . > metadata.json
NETWORK="$(<metadata.json jq -r '.network.interface[].ipv4.subnet[].address')"
MASK="$(<metadata.json jq -r '.network.interface[].ipv4.subnet[].prefix')"

if [ "$INDEX" = 0 ]; then
    systemctl enable rpcbind
    systemctl enable nfs-server
    systemctl enable nfs-lock
    systemctl enable nfs-idmap
    systemctl start rpcbind
    systemctl start nfs-server
    systemctl start nfs-lock
    systemctl start nfs-idmap

    mkdir -p /mnt/data/xcalar
    chmod 0777 /mnt/data/xcalar
    echo "/mnt/data/xcalar      ${NETWORK}/${MASK}(rw,sync,no_root_squash,no_all_squash)" | tee /etc/exports
    systemctl restart nfs-server
    if firewall-cmd --state; then
        firewall-cmd --permanent --zone=public --add-service=nfs
        firewall-cmd --reload
    fi
fi

# Set up the mount here, but don't mount until later
mkdir -p $XLRROOT
echo "${CLUSTER}0:/mnt/data/xcalar   $XLRROOT    nfs     defaults    0   0" | tee -a /etc/fstab

mkdir -p /etc/default/xcalar



curl -sSL "${INSTALLER_URL}" > xcalar-installer.sh

if ! bash -x ./xcalar-installer.sh --nostart; then
    echo >&2 "ERROR: Failed to install xcalar"
    exit 1
fi

MEMBERS=()
for NODEID in $(seq 0 $((COUNT-1))); do
    MEMBERS+=("${CLUSTER}${NODEID}.${DOMAIN}")
done

/opt/xcalar/scripts/genConfig.sh /etc/xcalar/template.cfg - "${MEMBERS[@]}" | tee /etc/xcalar/default.cfg

sed -r -i -e 's@^Constants.XcalarRootCompletePath=.*$@Constants.XcalarRootCompletePath='${XLRROOT}'@g' /etc/xcalar/default.cfg

mount ${XLRROOT}

service xcalar start
