#!/bin/bash

clear

#Check if root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

#wipe and upload to portal by default
wipe_only=false

#Set color variables for echo output
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
clear='\033[0m'

if dmidecode -s system-manufacturer | grep -qi "dell"; then
  mode=$(cctk --EmbSataRaid)
  sleep_block=$(cctk --BlockSleep)
  bios_reboot=false
  if [[ "$mode" == "EmbSataRaid=Raid" ]]; then
      sata_option=$(cctk --EmbSataRaid=Ahci | grep -oh "Setup Password")
      if [[ "$sata_option" == "Setup Password" ]]; then
        echo -e "${yellow}WARNING: BIOS Locked. Unable to update bios settings. The script may not be able to detect NVME drives in the device. Please shutdown the device and ensure there are no NVME drives installed before continuing.${clear}"
      else
        bios_reboot=true
      fi
  fi
  if [[ "$sleep_block" == "BlockSleep=Enabled" ]]; then
    sleep_option=$(cctk --BlockSleep=Disabled | grep -oh "Setup Password")
    if [[ "$sleep_option" == "Setup Password" ]]; then
      echo -e "${yellow}WARNING: BIOS Locked. Unable to update bios settings. The script may not be able to detect NVME drives in the device. Please shutdown the device and ensure there are no NVME drives installed before continuing.${clear}"
    else
      bios_reboot=true
    fi
  fi
  if [ $bios_reboot = true ]; then
    echo "Reboot required for script to continue! Restarting in 3 seconds..."
    sleep 3
    systemctl reboot
    exit
  fi
fi

#Define internet check function
check_internet () {
  #DHCP rebind
  interfaces=$(ip -o link show | awk -F': ' '{print $2}' | grep en)
  for i in $interfaces; do
    dhcpcd -n $i
  done

  #Check for internet connection
  wget -q --spider http://google.com
  if [ $? -ne 0 ]; then
    echo "Waiting for internet connection..."
    while : ; do
      wget -q --spider http://google.com

      if [ $? -eq 0 ]; then
        break
      fi
    done
  fi
}
verify_drive() {
  #check if drive is zeroed by scanning 10% of the drive for non-zeros
  echo "Verifying drive /dev/$1 is fully wiped..."
  total_bytes=$(lsblk -b --output SIZE -n -d /dev/$1)
  ten_percent_mbs=$(($total_bytes / 10000000))
  if dd if=/dev/$1 bs=1M count=$ten_percent_mbs status=none | pv -s $(echo $ten_percent_mbs)M | hexdump | head -n -2 | grep -q -m 1 -P '[^0 ]'; then
    echo -e "${red}Wipe Verification Failed!${clear}"
    wipe_passed=false
    return 1
  else
    echo -e "${green}Wipe Verification Passed!${clear}"
    return 0
  fi
}
#Define portal upload function
portal_upload () {
  #Submit asset info to portal
  echo "Submitting asset info to the portal..."
  if [[ -z "$jobNumber" ]]; then
    request=$(curl -sSf -X POST https://portal.er2.com/api/asset-inventory -H 'Content-Type: application/json' -d "{\"er2\": {\"er2_asset_tag\": \"$er2AssetTag\", \"asset_tag\": \"$assetTag\", \"wipe_method\": \"$wipe_method\"}, \"lshw\": $lshw_info, \"upower\": $upower_info}")
    exit_status=$?
  else
    request=$(curl -sSf -X POST https://portal.er2.com/api/asset-inventory -H 'Content-Type: application/json' -d "{\"er2\": {\"job_number\": \"$jobNumber\", \"er2_asset_tag\": \"$er2AssetTag\", \"asset_tag\": \"$assetTag\", \"wipe_method\": \"$wipe_method\"}, \"lshw\": $lshw_info, \"upower\": $upower_info}")
    exit_status=$?
  fi

  #check for cURL errors
  if [[ $exit_status -ne 0 ]]; then
     echo -e "${red}Portal Upload failed with exit code: $exit_status. Please ensure the asset has an internet connection${clear}"
     read -p "Press [Enter] key to retry upload..." none
     check_internet
     portal_upload
  fi

  #check for response errors
  if [[ $(echo $request | jq -r ".status") == "success" ]]; then
    if [[ $(echo $request | jq -r ".intune_registration") == "true" ]]; then
      intune_locked=true
    fi
    return 0
  else
    if [[ $(echo $request | jq -r ".status") == "error" ]]; then
      error_code=$(echo $request | jq -r ".error_code")
      error_message=$(echo $request | jq -r ".error")
      if [[ error_code -eq 4 ]]; then
        echo -e "${red}$error_message Please re-input asset data.${clear}"
        read -p "Re-Enter Job Number: " jobNumber
        portal_upload
      elif [[ error_code -eq 5 ]]; then
        echo -e "${red}$error_message Please re-input asset data.${clear}"
        read -p "(Optional) Re-Enter Job Number: " jobNumber
        read -p "Re-Enter ER2 Asset Tag: " er2AssetTag
        portal_upload
      elif [[ error_code -eq 6 ]]; then
        echo -e "${red}$error_message Please re-input asset data.${clear}"
        read -p "(Optional) Re-Enter Job Number: " jobNumber
        read -p "Re-Enter ER2 Asset Tag: " er2AssetTag
        portal_upload
      else
        echo -e "${red}Unknown error occurred. Error Code: ( $error_code ).${clear}"
        read -p "Press [Enter] key to continue..." none
        return 1
      fi
    fi
  fi
}

echo deep | sudo tee /sys/power/mem_sleep >> /dev/null

rtcwake -m mem -s 3 >> /dev/null
sleep 10

#Optionally enter job number
read -p "Enter Job Number: " jobNumber

#Input ER2 Asset Tag
read -p "Enter ER2 Asset Tag: " er2AssetTag

#If user entered nothing for er2 Asset Tag and Job Number then only wipe the drives and don't upload to portal
if [[ -z $er2AssetTag ]] && [[ -z $jobNumber ]]; then
  wipe_only=true
  echo "No job number or ER2 Asset Tag entered! Only wiping drives."
  sleep 3
else
  #Input Asset Tag
  read -p "(Optional) Enter Asset Tag: " assetTag

  #Get lshw json report of device information
  lshw_info=$(lshw -json -quiet)

  #Get battery info via upower dump
  upower_info=$(upower --dump | jc --upower)
fi

# Get a list of connected drives
drives=$(lsblk -d -o NAME,TYPE,TRAN | grep 'disk.*sata\|nvme' | awk '{print $1}')

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
    secure_erase_passed=true
    zero_erase_passed=true
    echo "attempting to wipe /dev/$drive..."
    # Check if drive is nvme
    if [[ "$drive" == "nvme"* ]]; then
      echo "Performing NVMe Secure erase on /dev/$drive..."
      nvme format /dev/$drive --ses=1 --force
      if [[ $? != 0 ]]; then
        echo -e "${red}Secure erase is not supported for /dev/$drive${clear}"
        secure_erase_passed=false
      fi
    # If ATA drive then wipe with ATA secure erase
    elif [[ "$drive" == "sd"* ]]; then
      if hdparm -I /dev/$drive | grep -q "min for SECURITY"; then
        security_time=$(hdparm -I /dev/$drive | grep -o -P "\d+min for SECURITY")
        enhanced_time=$(hdparm -I /dev/$drive | grep -o -P "\d+min for ENHANCED")
        if [[ $(echo $enhanced_time | grep -o -P "\d+") -le $(echo $security_time | grep -o -P "\d+") ]]; then
          echo "Enhanced Secure erase is supported for /dev/$drive. Estimated time to wipe: $enhanced_time"
          echo "Performing enhanced secure erase on /dev/$drive..."
          hdparm --security-set-pass p /dev/$drive >> /dev/null
          hdparm --security-erase-enhanced p /dev/$drive >> /dev/null
          if [[ $? != 0 ]]; then
            echo -e "${red}Secure erase not supported for /dev/$drive${clear}"
            secure_erase_passed=false
          else
            echo "Enhanced Secure erase complete for /dev/$drive."
          fi
        else
          echo "Secure erase is supported for /dev/$drive. Estimated time to wipe: $security_time"
          echo "Performing secure erase on /dev/$drive..."
          hdparm --security-set-pass p /dev/$drive >> /dev/null
          hdparm --security-erase p /dev/$drive >> /dev/null
          if [[ $? != 0 ]]; then
            secure_erase_passed=false
          else
            echo "Secure erase complete for /dev/$drive."
          fi
        fi
      else
        echo -e "${red}Secure erase not supported for /dev/$drive${clear}"
        secure_erase_passed=false
      fi
    else
      echo -e "${red}Secure erase is not supported for /dev/$drive${clear}"
      secure_erase_passed=false
    fi
    #If Secure erase fails, zero erase drive
    if [ $secure_erase_passed = false ]; then
      echo "Performing zero wipe on drive /dev/$drive due to secure erase failure. This will take significantly more time..."
      bytes=$(lsblk -b --output SIZE -n -d /dev/$drive)
      mbs=$(($bytes / 1000000))
      dd if=/dev/zero | pv -s $(echo $mbs)M | dd of=/dev/$drive bs=1M
      if [[ $? != 0 ]]; then
        zero_erase_passed=false
      fi
    fi
    if [ $zero_erase_passed = false ]; then
      wipe_passed=false
      break_loop=1
    else
      verify_drive $drive
      break_loop=$?
    fi
    if [ $break_loop -eq 1 ]; then
        break
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
if [ $wipe_only = false ]; then
    portal_upload
    upload_failed=$?
    if [ $upload_failed -eq 0 ]; then
        echo "Link to Asset Details:"
        qrencode -m 1 -t ANSI "https://portal.er2.com/asset/details/$(echo $request | jq -r ".asset_id")"
        echo "Processing Channel: $(echo $request | jq -r ".processing_channel")"
    fi
fi

if [ $intune_locked = true ]; then
  echo -e "${yellow}Device is Intune locked! Please mark asset as intune locked${clear}"
  read -p "Press [Enter] key to continue..." none
fi

if [ $wipe_passed = true ]; then
  if [ $upload_failed -eq 0 ]; then
    echo -e "${green}Successfully wiped device and uploaded to portal! Press [Enter] key to shutdown...${clear}"
    read -p "" none
  else
    echo -e "${yellow}Device successfully wiped but unable to upload to portal. Please mark asset for manual inventory. Press [Enter] key to shutdown...${clear}"
        read -p "" none
  fi
else
  if [ $upload_failed -eq 0 ]; then
    echo -e "${yellow}Asset uploaded to portal but drive failed to wipe! Please mark asset for manual destruction. press [Enter] key to shutdown...${clear}"
    read -p "" none
  else
    echo -e "${red}Failed to wipe drive and upload to portal! Please mark asset for manual destruction and manual asset inventory. press [Enter] key to shutdown...${clear}"
    read -p "" none
  fi
fi

systemctl poweroff