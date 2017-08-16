#!/bin/bash

COUNT="${1:-1}"
INSTALLER_URL="$2"
CLUSTER="${3:-${HOSTNAME%%[0-9]*}}"
INDEX="${4:-0}"
LICENSE="$5"
NFSMOUNT="$6"

# If on a single node instance, use the local host
# as the server
if [ -z "$NFSMOUNT" ] && [ "$COUNT" = 1 ]; then
    NFSMOUNT="${HOSTNAME}:/srv/share"
else
    NFSMOUNT="${CLUSTER}0:/srv/share"
fi

NFSHOST="${NFSMOUNT%%:*}"
SHARE="${NFSMOUNT##*:}"

if [ -r /etc/default/xcalar ]; then
    . /etc/default/xcalar
fi

XCE_HOME="${XCE_HOME:-/mnt/xcalar}"
XCE_CONFIG="${XCE_CONFIG:-/etc/xcalar/default.cfg}"
XCE_LICENSEDIR="${XCE_LICENSEDIR:-/etc/xcalar}"

if [ "$(getenforce)" = Enforcing ]; then
    setenforce Permissive
fi
sed -i -e 's/^SELINUX=enforcing.*$/SELINUX=permissive/g' /etc/selinux/config

yum update -y
yum install -y nfs-utils epel-release parted curl
yum install -y jq

# Determine our CIDR by querying the metadata service
curl -H Metadata:True "http://169.254.169.254/metadata/instance?api-version=2017-04-02&format=json" | jq . > metadata.json
NETWORK="$(<metadata.json jq -r '.network.interface[].ipv4.subnet[].address')"
MASK="$(<metadata.json jq -r '.network.interface[].ipv4.subnet[].prefix')"
LOCALIPV4="$(<metadata.json jq -r '.network.interface[].ipv4.ipAddress[].privateIpAddress')"

# Node 0 will host NFS shared storage for the cluster
if [ "$HOSTNAME" = "$NFSHOST" ]; then
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

    mkdir -p "${SHARE}/xcalar"
    chmod 0777 "${SHARE}/xcalar"

    # Download the installer as soon as we can and share it. We've seen perf issues (up to 20min)
    # when we had multiple nodes trying to download the installer at the same time.
    test -n "$INSTALLER_URL" && curl -sSL "$INSTALLER_URL" > "${SHARE}/xcalar/installer.sh"

    # Export the share to everyone in our CIDR block and mark it
    # as world r/w
    echo "${SHARE}/xcalar      ${NETWORK}/${MASK}(rw,sync,no_root_squash,no_all_squash)" | tee /etc/exports

    # Ensure NFS is running
    systemctl enable rpcbind
    systemctl enable nfs-server
    systemctl enable nfs-lock
    systemctl enable nfs-idmap
    systemctl start rpcbind
    systemctl start nfs-server
    systemctl start nfs-lock
    systemctl start nfs-idmap
    if firewall-cmd --state; then
        firewall-cmd --permanent --zone=public --add-service=nfs
        firewall-cmd --reload
    fi
fi

DOMAIN="$(dnsdomainname)"
MEMBERS=()
for NODEID in $(seq 0 $((COUNT-1))); do
    MEMBERS+=("${CLUSTER}${NODEID}")
done

while :; do
    ONLINE=()
    for NODE in "${MEMBERS[@]}"; do
        if host "${NODE}"; then
            ONLINE+=($NODE)
        fi
    done
    COUNT_ONLINE="${#ONLINE[@]}"
    if [ $COUNT_ONLINE -eq $COUNT ]; then
        break
    fi
    echo >&2 "Only ${COUNT_ONLINE}/${COUNT} members online ... sleeping"
    sleep 10
done

# Set up the mount for XcalarRoot
mkdir -p "$XCE_HOME"
echo "${NFSMOUNT}/xcalar   $XCE_HOME    nfs     defaults    0   0" | tee -a /etc/fstab
until mount "$XCE_HOME"; do
    echo >&2 "Unable to mount ${NFSMOUNT}/xcalar ... sleeping"
    sleep 10
done

mkdir -p "${XCE_HOME}/members"
echo "$LOCALIPV4        $(hostname -f)  $(hostname -s)" | tee "${XCE_HOME}/members/${INDEX}"

if [ -n "$INSTALLER_URL" ] && [ -f "${XCE_HOME}/installer.sh" ]; then
    cp -v "${XCE_HOME}/installer.sh" .
    if ! bash -x installer.sh --nostart; then
        echo >&2 "ERROR: Failed to run installer"
        exit 1
    fi
fi

/opt/xcalar/scripts/genConfig.sh /etc/xcalar/template.cfg - "${MEMBERS[@]}" | tee "$XCE_CONFIG"
sed -r -i -e 's@^Constants.XcalarRootCompletePath=.*$@Constants.XcalarRootCompletePath='$XCE_HOME'@g' "$XCE_CONFIG"
if [ "${#LICENSE}" -gt 1 ]; then
    if ! test -e "${XCE_LICENSEDIR}/XcalarLic.key"; then
        echo "$LICENSE" > "${XCE_LICENSEDIR}/XcalarLic.key"
    fi
fi

service xcalar start
