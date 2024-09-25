# ER2 DataMop Script

Bash script that wipes drives using ATA Secure erase for SATA drives and NVME Secure erase for NVME drives. Must run as root user.

## Dependencies
All can be installed using the apt package manager except for the Dell Command Configure Tool.
- jc
- jq
- nvme-cli
- pv
- cctk ([Dell Command Configure tool](https://www.dell.com/support/kbdoc/en-us/000178000/dell-command-configure))
- qrencode