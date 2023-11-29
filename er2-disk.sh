#!/bin/bash

#Check if root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

rtcwake -m mem -s 3

#Prompt if entering Job number
isEnteringJobNum=false
while true; do
  read -p "Entering Job Number? (y/n): " answer

  case $answer in
    [Yy])
      isEnteringJobNum=true
      break;;
    [Nn])
      break;;
    *)
      echo "Invalid input. Please enter 'y' or 'n'";;
  esac
done

#Get job number if entering
if [ $isEnteringJobNum = true ]; then
  read -p "Enter Job Number: " jobNumber
fi
#Input ER2 Asset Tag
read -p "Enter ER2 Asset Tag: " er2AssetTag

#Input Asset Tag
read -p "Enter Asset Tag: " assetTag

#Get lshw json report of device information
lshw_output=$(lshw -json -quiet)

# TODO Upload asset info to portal
#Create json object for post request
asset_info="{\"job_number\": \"$jobNumber\", \"er2_asset_tag\": \"$er2AssetTag\", \"asset_tag\": \"$assetTag\", \"lshw_output\": \"$lshw_output\"}"
#Create post request
#curl -x POST https://portal.er2.com/ -H 'Content-Type: application/json' -d $asset_info

# Get a list of connected drives
drives=$(lsblk -d -o NAME,TRAN | grep 'sata\|nvme' | awk '{print $1}')

# Loop through each drive and check if it supports ATA secure erase
for drive in $drives; do
  output=""
  pass=true
  echo "attempting to wipe /dev/$drive..."
  # Check if drive is nvme
  if [[ "$drive" == "nvme"* ]]; then
      # Check if crypto erase is supported
      if $(nvme id-ctrl /dev/$drive | grep fna) = "0x4"; then
        echo "NVMe Crypto erase is supported for /dev/$drive."
        echo "Performing NVMe crypto erase on /dev/$drive..."
        $output=$(nvme format /dev/$drive --ses=2 --force)
        if [ $output | grep "success" ]; then
          echo "NVMe crypto erase complete for /dev/$drive."
        else
          echo "Wipe Failed!"
          pass = false
        fi
      # Do Secure Erase if Crypto erase not supported
      else
        echo "NVMe Secure erase is supported for /dev/$drive."
        echo "Performing NVMe Secure erase on /dev/$drive..."
        $output=$(nvme format /dev/$drive --ses=1 --force)
        if $output | grep "success"; then
          echo "NVMe Secure erase complete for /dev/$drive."
          echo "NVMe drive"
        else
          echo "Wipe Failed!"
          pass = false
        fi
      fi
  # If ATA drive then wipe with ATA secure erase
  elif [[ "$drive" == "sd"* ]]; then
    if hdparm -I /dev/$drive | grep -q "supported: enhanced erase"; then
      echo "Secure erase is supported for /dev/$drive."
      echo "Performing secure erase on /dev/$drive..."
      hdparm --security-set-pass p /dev/$drive
      hdparm --security-erase-enhanced p /dev/$drive
      echo "Secure erase complete for /dev/$drive."
    else
      pass=false
    fi
  else
    echo "Secure erase is not supported for /dev/$drive"
    pass=false
  fi
  #check if drive is zeroed
  if dd if=/dev/$drive bs=2M count=100 status=none | hexdump | head -n 1 | grep -q '\[^0 '; then
    pass=false
  else
    echo "drive zeroed"
  fi
  if [ $pass = false ]; then
    read -p "Drive $drive failed to wipe... Please remove all drives from asset. press [Enter] key to shutdown..." none
    systemctl poweroff
  fi
done

read -p "Successfully wiped drive(s)! Press [Enter] key to shutdown..." none
systemctl poweroff
