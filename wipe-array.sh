#!/usr/bin/env bash
DEBUG=1
MAX_DRIVES=6
PORTAL_DOMAIN=dev.portal.er2.com
mapfile -t nvmes < <(nvme list -o json \
  | jq -r '.Devices[].DevicePath' \
  | grep -E '^/dev/nvme[0-9]+n1$')

declare -A drives
declare -a failedDrives=()
declare -a pids=()

missingDrives=0

driveCount=${#nvmes[@]}


end() {
  read -rp "The application has completed. Press any key to shutdown"
  if [ $DEBUG -eq 0 ]; then
    shutdown -h now
  fi
  exit 0;
}


if [ "$driveCount" -ne $MAX_DRIVES ]; then
  while :; do
    read -rp "This machine supports 6 drives but we didn't detect 6 drives. How many drives did you insert? " actualDrives || { echo; exit 130; }

   if [ "$actualDrives" -lt "$driveCount" ]; then
      echo "Invalid number of drives entered, since we detected $driveCount drives. Retrying..."
      continue
    fi
    break
  done

  if [ "$actualDrives" != "$driveCount" ]; then
    echo "Drive count mismatch. Expected $actualDrives drives, but found $driveCount drives. In this case, at the end of the process we will attempt to identify which device(s) failed to wipe."
    missingDrives=$(($actualDrives - $driveCount))
  else
    echo "Drive count matches the expected number of drives. Continuing..."
  fi
fi

for nvme in "${nvmes[@]}"; do
    exit_code=$(( $RANDOM % 1 ))
    echo "Wiping NVMe device: $nvme"
    if [ $DEBUG -eq 0 ]; then
      nvme format "$nvme" --ses=1 --force
      exit_code=$?
    else
      echo "Debug mode is on, skipping actual wipe command."
      sleep 1 && exit $exit_code &
    fi

    pid=($!)
    drives["$pid"]=$nvme
    pids+=("$pid")
done

for pid in "${pids[@]}"; do
  if [ $DEBUG -eq 1 ]; then
    echo "PID: $pid, drive: ${drives[$pid]}"
  fi

  wait "$pid"

  if [ $? -eq 0 ]; then
    #wipe was successful we should curl the endpoint
    echo "Wipe completed for device: ${drives[$pid]}... submitting to the portal"
    #get the serial number of the drive
    serial=$(udevadm info --query=property --name=${drives[$pid]} | awk -F= '/^ID_SERIAL_SHORT=/{v=$2; sub(/^[ \t\r\n]+/,"",v); sub(/[ \t\r\n]+$/,"",v); print v}')

    if [ $DEBUG -eq 0 ]; then
       curl -s "https://$PORTAL_DOMAIN/api/data-destruction/capture-wipe-data/?serialNumber=$serial&date=$(date '+%Y-%m-%d')&time=$(date '+%H-%M-%S')&eraseMethod=Secure%20Erase&status=Success&appName=Datamop&computerId=$(echo "$(hostname)"-"$(sudo dmidecode -s system-serial-number)")" > /dev/null
    else
      echo "Debug mode is on, skipping submission to application."
    fi
  else
      echo "Wipe failed or timed out for device: ${drives[$pid]}"
      failedDrives+=("${drives[$pid]}")
  fi
done

if [ ${#failedDrives[@]} -eq 0 ] && [ $missingDrives -eq 0 ]; then
    echo "All drives wiped successfully."
    end
fi

declare -A serials

for nvme in "${nvmes[@]}"; do
  serials["$nvme"]+="$(udevadm info --query=property --name="$nvme" | awk -F= '/^ID_SERIAL_SHORT=/{print $2}')"
done

if [ $missingDrives -ge 1 ]; then
  printf "\n\n\nOne or more drives are missing. We are reading the following serial numbers:\n"
  printf "%s\n" "${serials[@]}"
  printf "\n\nPlease begin scanning the serial numbers of the drives you inserted.\n"

  while :; do
    read -rp "We are missing $missingDrives drive(s), please scan a serial number: " scannedSerial || { echo; exit 130; }

    if ! grep -q "$scannedSerial" <<<"${serials[@]}"; then
      echo "Serial number $scannedSerial not found in the list of detected drives."
      while :; do
        read -rp "Are you sure this is the serial number? (y/n): " rescanChoice || { echo; exit 130; }
        case $rescanChoice in
          [Yy]* ) echo "Please destroy this drive" && break ;;
          [Nn]* ) continue 2;;
          * ) echo "Please answer yes (y) or no (n)." ;;
        esac
      done
      missingDrives=$(($missingDrives - 1))
    else
      echo "Serial number $scannedSerial found. Drive wiped successfully and can be placed into inventory."
    fi

    if [ $missingDrives -le 0 ]; then
      echo "All missing drives accounted for, continuing."
      break
    fi

  done
fi

if [ ${#failedDrives[@]} -gt 0 ]; then
  failedDriveCount=${#failedDrives[@]}
  printf "\n\nThe following serial numbers failed to wipe:\n"
  for failed in "${failedDrives[@]}"; do
    echo "${serials[$failed]}"      # :- gives a default if key not found
  done

  echo "Now we will attempt to locate the drive"

  while [ $failedDriveCount -gt 0 ]; do
    read -rp "We are looking for $failedDriveCount drives, please scan a serial number: " scannedSerial || { echo; exit 130; }
    if ! grep -q "$scannedSerial" <<<"${serials[@]}"; then
      echo "Serial number $scannedSerial not found in the list of failed drives."
      continue
    else
      echo "Serial number $scannedSerial has failed. Please destroy the drive"
      failedDriveCount=$(($failedDriveCount - 1))
    fi
  done
fi

end
