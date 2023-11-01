#!/bin/bash

#Check if root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

#Get device information
serial=$(sudo dmidecode -s system-serial-number)
make=$(sudo dmidecode -s system-manufacturer)
model=$(sudo dmidecode -s system-product-name)

#Input Asset Tag
echo "Enter Asset Tag:"
read assetTag

# Get a list of connected drives
drives=$(lsblk -o NAME,MODEL | grep 'disk' | awk '{print $1}')

# TODO Upload asset info to portal

# Loop through each drive and check if it supports ATA secure erase
for drive in $drives; do
  echo "Checking $drive..."
  # Check if drive is nvme
  if [[ $drive == /dev/nvme* ]]; then
      # Check if crypto erase is supported
      if $(nvme id-ctrl /dev/nvmeX | grep fna) = "0x4"; then
        echo "NVMe Crypto erase is supported for $drive."
        echo "Performing NVMe crypto erase on $drive..."
        nvme format $drive --ses=2
        echo "NVMe crypto erase complete for $drive."
      # TODO: Do Secure Erase if Crypto erase not supported
      else

      fi
  # If ATA drive then wipe with ATA secure erase
  elif hdparm --user-master u --security-mode m --security-help /dev/$drive | grep -q "supported"; then
    echo "Secure erase is supported for /dev/$drive."
    echo "Performing secure erase on /dev/$drive..."
    hdparm --user-master u --security-mode m --security-unlock /dev/$drive
    hdparm --user-master u --security-mode m --security-erase /dev/$drive
    echo "Secure erase complete for /dev/$drive."
  # TODO Implement wipe
  else
    echo "Secure erase is not supported for /dev/$drive."
  fi
done