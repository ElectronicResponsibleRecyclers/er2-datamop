#!/bin/bash

#Check if root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

#Prompt if entering Job number
isEnteringJobNum=false
while true; do
  read -p "Entering Job Number? (yes/no): " answer

  case $answer in
    [Yy]es)
      isEnteringJobNum=true
      break;;
    [Nn]o)
      break;;
    *)
      echo "Invalid input. Please enter 'yes' or 'no'";;
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
device_info=$(lshw -c system -json -quiet)

# TODO Upload asset info to portal

# Get a list of connected drives
drives=$(lsblk -o NAME,MODEL,TYPE | grep 'disk' | awk '{print $1}')

# Loop through each drive and check if it supports ATA secure erase
for drive in $drives; do
  output=""
  pass=true
  echo "Checking $drive..."
  # Check if drive is nvme
  if [[ $drive == /dev/nvme* ]]; then
      # Check if crypto erase is supported
      if $(nvme id-ctrl $drive | grep fna) = "0x4"; then
        echo "NVMe Crypto erase is supported for $drive."
        echo "Performing NVMe crypto erase on $drive..."
        $output=$(nvme format $drive --ses=2 --force)
        if [ $output | grep "success" ]; then
          echo "NVMe crypto erase complete for $drive."
        else
          echo "Wipe Failed!"
          $pass = false
        fi
      # Do Secure Erase if Crypto erase not supported
      else
        echo "NVMe Secure erase is supported for $drive."
        echo "Performing NVMe Secure erase on $drive..."
        $output=$(nvme format $drive --ses=1 --force)
        if [ $output | grep "success" ]; then
          echo "NVMe Secure erase complete for $drive."
        else
          echo "Wipe Failed!"
          $pass = false
        fi
      fi
  # If ATA drive then wipe with ATA secure erase
  elif hdparm --user-master u --security-mode m --security-help /dev/$drive | grep -q "supported"; then
    echo "Secure erase is supported for /dev/$drive."
    echo "Performing secure erase on /dev/$drive..."
    hdparm --user-master u --security-mode m --security-unlock /dev/$drive
    $output=$(hdparm --user-master u --security-mode m --security-erase /dev/$drive)

    echo "Secure erase complete for /dev/$drive."
  # TODO Implement wipe
  else
    echo "Secure erase is not supported for /dev/$drive."
  fi
  if [ $pass = false ]; then
    read -p "Drive $drive failed to wipe... Please remove all asset drives and press [Enter] key to shutdown..."
    shutdown
  fi
done

read -p "Successfully wiped drive! Press [Enter] key to shutdown..."
shutdown