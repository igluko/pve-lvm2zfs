#!/bin/bash

#https://stackoverflow.com/questions/5947742/how-to-change-the-output-color-of-echo-in-linux
#printf "I ${RED}love${NC} Stack Overflow\n"
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
OK="${GREEN}ok${NC}"
FAIL="${RED}fail${NC}"

# get target Node IP (new server)
while true; do
    read -p "Enter NEW server IP (destination): " dstNode
    ssh-copy-id root@$dstNode 2>/dev/null
    ret=$?
    if [ $ret -eq 0 ]; then
        printf "[$OK] Connect to $dstNode success!"
        echo
        break
    else
        printf "[$FAIL] Connect to $dstNode error, Please try again..\n"
    fi
done

# Print current lxc containers and virtual machines
eval "pct list"
ret=$?
if [ $ret -eq 0 ]; then
    printf "[$OK] pct list success!"
    echo
else
    printf "[$FAIL] pct list error, Exiting..\n"
    exit 1
fi
eval "qm list"
ret=$?
if [ $ret -eq 0 ]; then
    printf "[$OK] qm list success!"
    echo
else
    printf "[$FAIL] qm list error, Exiting..\n"
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
        printf "[$OK] ID set successfully!"
        echo
    else
        printf "[$FAIL] ID not found among containers and virtual machines, Please try again..\n"
        #exit 1
    fi

    # is Container
    if [ $isCT -eq 0 ]; then
        printf "[$OK] VMID $VMID is a container"
        echo
        # shitdown or stop?
        while true; do
            eval "pct list | awk ' \$1==\"$VMID\" && \$2==\"stopped\" ' | grep -q \"\" "
            ret=$?
            if [ $ret -eq 0 ]; then
                printf "[$OK] Container $VMID is already stopped!"
                echo
                break
            else
                printf "[$OK] Container $VMID is running. It's must be stopped!"
                echo
            fi
            read -p "Shutdown[s] the container or Poweroff[p] the container? " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Ss]$ ]]
            then
                eval "pct shutdown $VMID"
                ret=$?
                if [ $ret -eq 0 ]; then
                    printf "[$OK] Container $VMID has successfully shutdown"
                    echo
                    break
                else
                    printf "[$FAIL] Container $VMID has FAILED shutdown"
                    echo
                    continue
                fi
            fi
            if [[ $REPLY =~ ^[Pp]$ ]]
            then
                eval "pct stop $VMID"
                ret=$?
                if [ $ret -eq 0 ]; then
                    printf "[$OK] Container $VMID has successfully poweroff"
                    echo
                    break
                else
                    printf "[$FAIL] Container $VMID has FAILED poweroff"
                    echo
                    continue
                fi
            fi
        done
    fi
    # is VM
    if [ $isVM -eq 0 ]; then
        printf "[$FAIL] VMID $VMID is a virtual machine. Not yet implemented."
        echo    
    fi
done



