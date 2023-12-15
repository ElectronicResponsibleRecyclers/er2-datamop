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
    request=$(curl -s -X POST https://feature-pa-4383-endpoint-for-submitting-assets.er2.com/api/asset-inventory -H 'Content-Type: application/json' -d "{\"er2\": {\"er2_asset_tag\": \"$er2AssetTag\", \"asset_tag\": \"$assetTag\", \"wipe_method\": \"$wipe_method\"}, \"lshw\": $lshw_info}")
  else
    request=$(curl -s -X POST https://feature-pa-4383-endpoint-for-submitting-assets.er2.com/api/asset-inventory -H 'Content-Type: application/json' -d "{\"er2\": {\"job_number\": \"$jobNumber\", \"er2_asset_tag\": \"$er2AssetTag\", \"asset_tag\": \"$assetTag\", \"wipe_method\": \"$wipe_method\"}, \"lshw\": $lshw_info}")
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

rtcwake -m mem -s 3

#Optionally enter job number
read -p "(Optional) Enter Job Number: " jobNumber

#Input ER2 Asset Tag
read -p "Enter ER2 Asset Tag: " er2AssetTag

#Input Asset Tag
read -p "Enter Asset Tag: " assetTag

#Get lshw json report of device information
lshw_info=$(lshw -json -quiet)

# Get a list of connected drives
drives=$(lsblk -d -o NAME,TRAN | grep 'sata\|nvme' | awk '{print $1}')

wipe_passed=true
# Loop through each drive and check if it supports ATA secure erase
for drive in $drives; do
  echo "attempting to wipe /dev/$drive..."
  # Check if drive is nvme
  if [[ "$drive" == "nvme"* ]]; then
      # Check if crypto erase is supported
      if nvme id-ctrl /dev/$drive -H | grep -q "Crypto Erase Supported"; then
        echo "NVMe Crypto erase is supported for /dev/$drive."
        echo "Performing NVMe crypto erase on /dev/$drive..."
        output=$(nvme format /dev/$drive --ses=2 --force)
        if echo $output | grep -q "Success"; then
          echo "NVMe crypto erase complete for /dev/$drive."
        else
          echo "Wipe Failed!"
          wipe_passed=false
          break
        fi
      # Do Secure Erase if Crypto erase not supported
      else
        echo "NVMe Secure erase is supported for /dev/$drive."
        echo "Performing NVMe Secure erase on /dev/$drive..."
        output=$(nvme format /dev/$drive --ses=1 --force)
        if echo $output | grep -q  "Success"; then
          echo "NVMe secure erase complete for /dev/$drive."
        else
          echo "Wipe Failed!"
          wipe_passed=false
          break
        fi
      fi
  # If ATA drive then wipe with ATA secure erase
  elif [[ "$drive" == "sd"* ]]; then
    if hdparm -I /dev/$drive | grep -q "supported: enhanced erase"; then
      echo "Secure erase is supported for /dev/$drive."
      echo "Performing secure erase on /dev/$drive..."
      hdparm --security-set-wipe_passed p /dev/$drive
      hdparm --security-erase-enhanced p /dev/$drive
      echo "Secure erase complete for /dev/$drive."
    else
      echo "Secure erase not supported for /dev/$drive"
      wipe_passed=false
      break
    fi
  else
    echo "Secure erase is not supported for /dev/$drive"
    wipe_passed=false
    break
  fi
  #check if drive is zeroed
  # TODO Currently broken. Must check 10% of drive for zeros from random sectors.
#  if dd if=/dev/$drive bs=2M count=100 status=none | hexdump | head -n 1 | grep -q '\[^0 '; then
#    wipe_passed=false
#    break
#  fi
done
wipe_method="Secure Erase"
if [ $wipe_passed = false ]; then
  wipe_method="Destroyed"
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