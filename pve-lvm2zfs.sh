#!/bin/bash

#https://stackoverflow.com/questions/5947742/how-to-change-the-output-color-of-echo-in-linux
#printf "I ${RED}love${NC} Stack Overflow\n"
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
OK="${GREEN}ok${NC}"
FAIL="${RED}fail${NC}"


# try to read preconfigured server address from env file
if [ -f ".env" ]; then
    dstNode=`cat .env | xargs`
fi

# get target Node IP (new server)
while true; do
    read -e -p "Enter NEW server IP (destination): " -i $dstNode dstNode
    ssh-copy-id -o ConnectTimeout=5 root@$dstNode 2>/dev/null
    ret=$?
    if [ $ret -eq 0 ]; then
        printf "[$OK] Connect to $dstNode success! \n"
        break
    else
        printf "[$FAIL] Connect to $dstNode error, Please try again.. \n"
    fi
done

SSH="ssh -o BatchMode=yes -o ConnectTimeout=5 root@$dstNode"

# Print current lxc containers and virtual machines
eval "pct list"
ret=$?
if [ $ret -eq 0 ]; then
    printf "[$OK] pct list success! \n"
else
    printf "[$FAIL] pct list error, Exiting.. \n"
    exit 1
fi
eval "qm list"
ret=$?
if [ $ret -eq 0 ]; then
    printf "[$OK] qm list success! \n"
else
    printf "[$FAIL] qm list error, Exiting.. \n"
    exit 1
fi

# Chose number vm\ct for transfer to new server
while true; do
    read -p "Enter the container or virtual machine number to migrate to another server: " VMID
    eval "pct list | awk ' \$1==$VMID ' | grep -q \"\" "
    isCT=$?
    eval "qm list | awk ' \$1==$VMID ' | grep -q \"\" "
    isVM=$?
    if [ $isCT -eq 0 ] || [ $isVM -eq 0 ]; then
        printf "[$OK] ID set successfully! \n"
    else
        printf "[$FAIL] ID not found among containers and virtual machines, Please try again.. \n"
        continue
    fi
    # Get new ID
    VMID_NEW=$VMID
    while true; do
        read -e -p "Enter NEW ID on target server: " -i $VMID_NEW VMID_NEW
        # check is ID available
        eval "$SSH grep -Eq '.$VMID_NEW.:' /etc/pve/.vmlist"
        ret=$?
        if [ $ret -eq 0 ]; then
            printf "[$FAIL] ID $VMID_NEW already in use! \n"
            #read -p "Enter another ID: " VMID_NEW
            continue
        else
            printf "[$OK] ID $VMID_NEW is available on target server \n"
            break
        fi
    done

    # is Container
    if [ $isCT -eq 0 ]; then
        printf "[$OK] VMID $VMID is a container \n"
        # shutdown or stop?
        while true; do
            eval "pct list | awk ' \$1==\"$VMID\" && \$2==\"stopped\" ' | grep -q \"\" "
            ret=$?
            if [ $ret -eq 0 ]; then
                printf "[$OK] Container $VMID is already stopped! \n"
                break
            else
                printf "[$OK] Container $VMID is running. It's must be stopped! \n"
            fi
            read -p "Shutdown[s] the container or Poweroff[p] the container? " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Ss]$ ]]
            then
                eval "pct shutdown $VMID"
                ret=$?
                if [ $ret -eq 0 ]; then
                    printf "[$OK] Container $VMID has successfully shutdown \n"
                    break
                else
                    printf "[$FAIL] Container $VMID has FAILED shutdown \n"
                    continue
                fi
            fi
            if [[ $REPLY =~ ^[Pp]$ ]]
            then
                eval "pct stop $VMID"
                ret=$?
                if [ $ret -eq 0 ]; then
                    printf "[$OK] Container $VMID has successfully poweroff \n"
                    break
                else
                    printf "[$FAIL] Container $VMID has FAILED poweroff \n"
                    continue
                fi
            fi
        done
        # Find lvm for rootfs
        eval "ls -l /dev/pve | grep -q vm-$VMID-disk-0"
        ret=$?
        if [ $ret -eq 0 ]; then
            printf "[$OK] LVM disk found \n"
        else
            printf "[$FAIL] LVM disk NOT found! \n"
            exit 255
        fi
        # iterator for lvm
        for vol in $(ls /dev/pve | grep -oE vm-$VMID-disk-[0-9+])
        do
            echo " $vol"
            # Mount LVM
            eval "mkdir -p /mnt/$vol; umount /mnt/$vol 2>/dev/null; mount /dev/pve/$vol /mnt/$vol"
            ret=$?
            if [ $ret -eq 0 ]; then
                printf "[$OK] LVM $vol mounted to /mnt/$vol \n"
            else
                printf "[$FAIL] LVM $vol mount to /mnt/$vol error! \n"
                exit 255
            fi
            dataset="subvol-$VMID_NEW-disk-${vol#*-*-*-}" # https://stackoverflow.com/questions/428109/extract-substring-in-bash
            # Get LV size
            lvsize=$(lvdisplay /dev/pve/$vol --units b | grep "LV Size" | grep -oE [0-9]+)
            echo "lvsize is $lvsize b"
            # Create zfs dataset on dst server
            eval "$SSH  zfs create -o acltype=posixacl -o xattr=sa -o refquota=$lvsize rpool/data/$dataset"
            ret=$?
            if [ $ret -eq 0 ]; then
                printf "[$OK] Dataset $dataset created \n"
            else
                printf "[$FAIL] Dataset $dataset create error! \n"
                exit 255
            fi
            # Copy rootfs to dst server
            eval "rsync -az --info=progress2 /mnt/$vol/ root@$dstNode:/rpool/data/$dataset/"
            ret=$?
            if [ $ret -eq 0 ]; then
                printf "[$OK] rsync successfully copied $vol to $dataset on dst server \n"
            else
                printf "[$FAIL] rsync failed copy $vol to $dataset on dst server! \n"
                exit 255
            fi
        done
        
        # Copy config file
        eval "scp /etc/pve/local/lxc/$VMID.conf root@$dstNode:/etc/pve/local/lxc/$VMID_NEW.conf"
        ret=$?
        if [ $ret -eq 0 ]; then
            printf "[$OK] Config file copied \n"
        else
            printf "[$FAIL] Config file copy error! \n"
            exit 255
        fi
        # Transform config on dst server
        eval "$SSH sed -i -E \'s/local-lvm:vm-$VMID/local-zfs:subvol-$VMID_NEW/\' /etc/pve/local/lxc/$VMID_NEW.conf"
        ret=$?
        if [ $ret -eq 0 ]; then
            printf "[$OK] Config file transformed \n"
        else
            printf "[$FAIL] Config file transform error! \n"
            exit 255
        fi
    fi
    # is VM
    if [ $isVM -eq 0 ]; then
        printf "[$OK] VMID $VMID is a VM \n"
        # shutdown or stop?
        while true; do
            eval "qm list | awk ' \$1==\"$VMID\" && \$3==\"stopped\" ' | grep -q \"\" "
            ret=$?
            if [ $ret -eq 0 ]; then
                printf "[$OK] VM $VMID is already stopped! \n"
                break
            else
                printf "[$OK] VM $VMID is running. It's must be stopped! \n"
            fi
            read -p "Shutdown[s] the VM or Poweroff[p] the VM? " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Ss]$ ]]
            then
                eval "qm shutdown $VMID"
                ret=$?
                if [ $ret -eq 0 ]; then
                    printf "[$OK] VM $VMID has successfully shutdown \n"
                    break
                else
                    printf "[$FAIL] VM $VMID has FAILED shutdown \n"
                    continue
                fi
            fi
            if [[ $REPLY =~ ^[Pp]$ ]]
            then
                eval "qm stop $VMID"
                ret=$?
                if [ $ret -eq 0 ]; then
                    printf "[$OK] VM $VMID has successfully poweroff \n"
                    break
                else
                    printf "[$FAIL] VM $VMID has FAILED poweroff \n"
                    continue
                fi
            fi
        done
        # Find lvm for rootfs
        eval "ls -l /dev/pve | grep -q vm-$VMID-disk-0"
        ret=$?
        if [ $ret -eq 0 ]; then
            printf "[$OK] LVM disk found \n"
        else
            printf "[$FAIL] LVM disk NOT found! \n"
            exit 255
        fi
        # iterator for lvm
        for vol in $(ls /dev/pve | grep -oE vm-$VMID-disk-[0-9+])
        do
            echo " $vol"
            zvol="vm-$VMID_NEW-disk-${vol#*-*-*-}"
            # Get LV size
            lvsize=$(lvdisplay /dev/pve/$vol --units b | grep "LV Size" | grep -oE [0-9]+)
            echo "lvsize is $lvsize b"
            # Create zfs dataset on dst server
            eval "$SSH  zfs create -s -V $lvsize rpool/data/$zvol"
            ret=$?
            if [ $ret -eq 0 ]; then
                printf "[$OK] zvol $zvol created \n"
            else
                printf "[$FAIL] zvol $zvol create error! \n"
                exit 255
            fi
            # Copy rootfs to dst server
            eval "pv -tpreb /dev/pve/$vol | zstd -1 - | ssh root@$dstNode 'zstd -d | dd of=/dev/zvol/rpool/data/$zvol'"
            ret=$?
            if [ $ret -eq 0 ]; then
                printf "[$OK] dd successfully copied $vol to $zvol on dst server \n"
            else
                printf "[$FAIL] dd failed copy $vol to $zvol on dst server! \n"
                exit 255
            fi
        done
        # Copy config file
        eval "scp /etc/pve/local/qemu-server/$VMID.conf root@$dstNode:/etc/pve/local/qemu-server/$VMID_NEW.conf"
        ret=$?
        if [ $ret -eq 0 ]; then
            printf "[$OK] Config file copied \n"
        else
            printf "[$FAIL] Config file copy error! \n"
            exit 255
        fi
        # Transform config on dst server
        eval "$SSH sed -i -E \'s/local-lvm:vm-$VMID/local-zfs:vm-$VMID_NEW/\' /etc/pve/local/qemu-server/$VMID_NEW.conf"
        ret=$?
        if [ $ret -eq 0 ]; then
            printf "[$OK] Config file transformed \n"
        else
            printf "[$FAIL] Config file transform error! \n"
            exit 255
        fi
    fi
done

# pvesh get /nodes/`hostname`/storage --output=json-pretty | jq -r ['.[] | select(.type=="lvmthin")'.storage][0]


