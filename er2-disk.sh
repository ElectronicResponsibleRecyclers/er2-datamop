#!/bin/bash

#Check if root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

#Set color variables for echo output
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
clear='\033[0m'

#Define portal upload function
portal_upload () {
  #Submit asset info to portal
  echo "Submitting asset info to the portal..."
  if [[ -z "$jobNumber" ]]; then
    request=$(curl -s -X POST https://feature-pa-4383-endpoint-for-submitting-assets.er2.com/api/asset-inventory -H 'Content-Type: application/json' -d "{\"er2\": {\"er2_asset_tag\": \"$er2AssetTag\", \"asset_tag\": \"$assetTag\", \"wipe_method\": \"$wipe_method\"}, \"lshw\": $lshw_info, \"upower\": $upower_info}")
  else
    request=$(curl -s -X POST https://feature-pa-4383-endpoint-for-submitting-assets.er2.com/api/asset-inventory -H 'Content-Type: application/json' -d "{\"er2\": {\"job_number\": \"$jobNumber\", \"er2_asset_tag\": \"$er2AssetTag\", \"asset_tag\": \"$assetTag\", \"wipe_method\": \"$wipe_method\"}, \"lshw\": $lshw_info, \"upower\": $upower_info}")
  fi

  #check for errors
  if [[ $(echo $request | jq -r ".status") == "success" ]]; then
    if [[ $(echo $request | jq -r ".intune_registration") == "true" ]]; then
      intune_locked=true
    fi
  else
    if [[ $(echo $request | jq -r ".error") ]]; then
      error_code=$(echo $request | jq -r ".error_code")
      if [[ error_code -eq 1 ]]; then
        echo -e "${yellow}Access to portal upload denied. Please ensure this you are running this while connected to the ER2 network${clear}"
        read -p "Connect to the ER2 network and press [Enter] to try again" none
        portal_upload
      elif [[ error_code -eq 2 ]]; then
        echo -e "${yellow}Failed to verify intune status!${clear}"
        read -p "Press [Enter] to try again" none
        portal_upload
      elif [[ error_code -eq 3 ]]; then
        echo -e "${yellow}Serial Number already exists in portal! Device may have already been inventoried${clear}"
        read -p "Press [Enter] to continue" none
      elif [[ error_code -eq 4 ]]; then
        echo -e "${yellow}Job not found! Please input the job number${clear}"
        read -p "Enter Job Number: " jobNumber
        portal_upload
      elif [[ error_code -eq 5 ]]; then
        echo -e "${yellow}ER2 Asset Tag not found! Please reenter the ER2 Asset Tag${clear}"
        read -p "Enter ER2 Asset Tag: " er2AssetTag
        portal_upload
      else
        echo -e "${red}Unknown error occurred. Error Code: ( $error_code ).${clear}"
        read -p "Press [Enter] key to continue..." none
      fi
    fi
  fi
}

rtcwake -m mem -s 3 >> /dev/null

#Optionally enter job number
read -p "(Optional) Enter Job Number: " jobNumber

#Input ER2 Asset Tag
read -p "Enter ER2 Asset Tag: " er2AssetTag

#Input Asset Tag
read -p "Enter Asset Tag: " assetTag

#Get lshw json report of device information
lshw_info=$(lshw -json -quiet)

#Get battery info via upower dump
upower_info=$(upower --dump | jc --upower)

# Get a list of connected drives
drives=$(lsblk -d -o NAME,TRAN | grep 'sata\|nvme' | awk '{print $1}')

wipe_passed=true
if [[ -z "$drives" ]]; then
  echo -e "${yellow}Warning! This script is unable to detect any drives inside this asset. Please check whether or not the asset contains any drives."
  echo "If the asset does contain drives please shutdown the asset, ensure that all drives are connected properly and power on the asset."
  echo -e "${red}If this is the second time this warning has popped up and there are drives in the asset, run the script until completion, remove all drives from the asset and mark them for destruction.${yellow}"
  echo -e "If the asset does not contain drives then do not shut the asset down and continue running the script to upload the asset's information to the portal.${clear}"
  read -p "Would you like to shutdown the device? (y/N)"
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    systemctl poweroff
  fi
else
  # Loop through each drive and check if it supports ATA secure erase
  for drive in $drives; do
    echo "attempting to wipe /dev/$drive..."
    # Check if drive is nvme
    if [[ "$drive" == "nvme"* ]]; then
        # Check if crypto erase is supported
        if nvme id-ctrl /dev/$drive -H | grep -q "Crypto Erase Supported"; then
          echo "NVMe Crypto erase is supported for /dev/$drive."
          echo "Performing NVMe crypto erase on /dev/$drive..."
          nvme format /dev/$drive --ses=2 --force
        # Do Secure Erase if Crypto erase not supported
        else
          echo "NVMe Secure erase is supported for /dev/$drive."
          echo "Performing NVMe Secure erase on /dev/$drive..."
          nvme format /dev/$drive --ses=1 --force
        fi
    # If ATA drive then wipe with ATA secure erase
    elif [[ "$drive" == "sd"* ]]; then
      if hdparm -I /dev/$drive | grep -q "min for SECURITY"; then
        security_time=$(hdparm -I /dev/$drive | grep -o -P "\d+min for SECURITY")
        enhanced_time=$(hdparm -I /dev/$drive | grep -o -P "\d+min for ENHANCED")
        if [[ $(echo $enhanced_time | grep -o -P "\d+") -le $(echo $security_time | grep -o -P "\d+") ]]; then
          echo "Enhanced Secure erase is supported for /dev/$drive."
          echo "Performing enhanced secure erase on /dev/$drive..."
          hdparm --security-set-pass p /dev/$drive >> /dev/null
          hdparm --security-erase-enhanced p /dev/$drive >> /dev/null
          echo "Enhanced Secure erase complete for /dev/$drive."
        else
          echo "Secure erase is supported for /dev/$drive."
          echo "Performing secure erase on /dev/$drive..."
          hdparm --security-set-pass p /dev/$drive >> /dev/null
          hdparm --security-erase p /dev/$drive >> /dev/null
          echo "Secure erase complete for /dev/$drive."
        fi
      else
        echo -e "${red}Secure erase not supported for /dev/$drive"
        wipe_passed=false
        break
      fi
    else
      echo -e "${red}Secure erase is not supported for /dev/$drive"
      wipe_passed=false
      break
    fi
    #check if drive is zeroed by scanning 10% of the drive for non-zeros
    echo "Verifying drive /dev/$drive is fully wiped..."
    total_bytes=$(lsblk -b --output SIZE -n -d /dev/$drive)
    ten_percent_mbs=$(($total_bytes / 10000000))
    if dd if=/dev/$drive bs=1M count=$ten_percent_mbs status=none | pv -s $(echo $ten_percent_mbs)M | hexdump | head -n -2 | grep -q -m 1 -P '[^0 ]'; then
      echo -e "${red}Wipe Verification Failed!${clear}"
      wipe_passed=false
      break
    else
      echo -e "${green}Wipe Verification Passed!${clear}"
    fi
  done
fi
#Set wipe Method
if [ $wipe_passed = false ]; then
  wipe_method="Destroyed"
else
  wipe_method="Secure Erase"
fi

intune_locked=false
portal_upload

if [ $intune_locked = true ]; then
  echo -e "${yellow}Device is Intune locked!!! Please place Intune sticker on device!!!${clear}"
  read -p "Press [Enter] key to continue..." none
fi

if [ $wipe_passed = true ]; then
  echo -e "${green}Successfully wiped device! Press [Enter] key to shutdown...${clear}"
  read -p "" none
else
  echo -e "${red}Device drive failed to wipe correctly!!! Please remove all drives from asset and mark for manual destruction. press [Enter] key to shutdown...${clear}"
  read -p "" none
fi

systemctl poweroff