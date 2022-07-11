#!/bin/bash
#    Name:
#  Author: Aut0exec
#    Date: March 23, 2022
# Version: 1.0
# Purpose: This script can be used to configure a virtualbox VM running windows with proper ACPI/DMI
#          tables to allow windows to activate off the codes contained within the host's firmware.
#
#  Issues: This process doesn't work if guest is booted via EFI
#          -- At the moment, unable to determine how/what to passthrough in VBox

usage() {

	echo -e "Usage: $PROGNAME '<VM_Name>'"
	echo -e "\t<VM_Name> : Name of Windows VM"
	echo -e "\t\t    Quote name of VM if it contains spaces"
	echo -e "\t-h|--help : Display this message"
	echo -e "\n\rSynopsis:"
	echo -e "\tThis tool is used to configure necessary firmware tables"
	echo -e "\tfor a virtualbox Windows VM to have the ability to activate"
	echo -e "\twith the license code contained within the host's firmware."
	echo -e "\nProcess:"
	echo -e "\t1) Create the new Windows VM - DO NOT RUN INSTALLATION."
	echo -e "\t2) Run this script and provide the name for the new Windows VM"
	echo -e "\t   - Requires root or sudo rights (see note below about root usage)"
	echo -e "\t3) Once the script completes successfully, run the Windows installer ISO within the VM "
	echo -e "\nDisclaimers:"
	echo -e "\r\tCurrently can't pass license data properly when booting vie EFI!"
	echo -e "\n\r\tThis process has been tested on: "
	echo -e "\tDevuan 4 Chimaera, VirtualBox V6.1.34 and V6.1.35 running a Windows 10 VM."
	exit 99
}

get_vm_list() {

	# Read through list of Virtual machines and change field seperator to |
	# to avoid issues with virtual machines that have spaces in the name
	while IFS='|' read -r name vmuuid; do
		VM_LIST_ARRAY["$name"]="$vmuuid"
	done < <(vboxmanage list vms | sed -E 's/^"(.*)"\ \{(.*)}$/\1\|\2/g')
}

get_vm_os() {

	local guest_id=$1
	local firmware_type=$(vboxmanage showvminfo --machinereadable "$guest_id" | sed -n 's/firmware="\(.*\)"$/\1/p')
	GUEST_OS=$(vboxmanage showvminfo --machinereadable "$guest_id" | sed -n 's/ostype="\(.*\)"$/\1/p')

	if grep -qi "windows" <<< "$GUEST_OS"; then
		if grep -qi "bios" <<< "$firmware_type"; then
			return 0 # Windows in BIOS boot
		fi
		return 1 # Windows in EFI Boot
	else
		return 2 # Not Windows
	fi
}

get_vm_cfg_dir() {

	local guest_id=$1
	GUEST_CFG_PATH=$(vboxmanage showvminfo --machinereadable "$guest_id" | sed -n 's/CfgFile="\(.*\)\/.*\.vbox"$/\1/p')

	if [ -d "$GUEST_CFG_PATH" ]; then
		return 0
	else
		return 1
	fi
}

create_guest_tables() {

	local guest_cfg_dir="$1"

	if [ "$SUDO" == 'su -c' ];then
		echo -e "\n\n\rINFO: Running 'su -c' and prompting for root user's password."
	fi

	export GUEST_CFG_PATH MSDM_TAB SLIC_TAB DMI_TAB DMI_TYPE0_OFFSET DMI_TYPE1_OFFSET USER

	${SUDO} 'dd if="$MSDM_TAB" of="${GUEST_CFG_PATH}/msdm.bin" &> /dev/null && \
             dd if="$SLIC_TAB" of="${GUEST_CFG_PATH}/slic.bin" status=none &> /dev/null && \
             dd if="$DMI_TAB" of="${GUEST_CFG_PATH}/dmi_type0.bin" skip="$(($DMI_TYPE0_OFFSET))" bs=1 count=54 status=none &> /dev/null && \
             dd if="$DMI_TAB" of="${GUEST_CFG_PATH}/dmi_type1.bin" skip="$(($DMI_TYPE1_OFFSET))" bs=1 count=102 status=none &> /dev/null && \
             chown $USER:$USER "${GUEST_CFG_PATH}/"{msdm.bin,slic.bin,dmi_type0.bin,dmi_type1.bin}'

	if [ $? -ne 0 ]; then
		return 1
	else
		echo -e "INFO: Copied necessary firmware tables to $GUEST_CFG_PATH..."
		return 0
	fi

}

update_vm_conf() {

	local guest_cfg_dir="$1"
	local guest_uuid="$2"
	local vm_acpi_path='VBoxInternal/Devices/acpi/0/Config'

	echo "INFO: Creating proper configuration file entries..."

	vboxmanage setextradata "$guest_uuid" "${vm_acpi_path}/CustomTable0" "${guest_cfg_dir}/dmi_type0.bin" &> /dev/null && \
	vboxmanage setextradata "$guest_uuid" "${vm_acpi_path}/CustomTable1" "${guest_cfg_dir}/dmi_type1.bin" &> /dev/null && \
	vboxmanage setextradata "$guest_uuid" "${vm_acpi_path}/CustomTable2" "${guest_cfg_dir}/msdm.bin" &> /dev/null && \
	vboxmanage setextradata "$guest_uuid" "${vm_acpi_path}/CustomTable3" "${guest_cfg_dir}/slic.bin" &> /dev/null

	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to create all configuration entries."
		return 1
	else
		return 0
	fi
}

user_privs() {

	echo "INFO: Checking user rights to determine proper installation method."
	local adm_rights=$(groups | egrep -i '^sudo$|^adm$|^wheel$' &> /dev/null; echo $?)
	command -v sudo &> /dev/null
	if [ $? -eq 0 ] && [ $adm_rights -eq 0 ]; then
    	SUDO=$(which sudo)
	    echo "INFO: Sudo installed. Checking if user can run commands using sudo."
	    if [ ! $($SUDO -l) > /dev/null ]; then
    	    echo "WARN: Sudo installed but appears $USER can't run commands with sudo."
	        echo "INFO: Switching to 'su -c' which will prompt for root's password."
    	    sleep 2
	        SUDO='su -c'
    	fi
	else
    	echo "INFO: Using 'su -c'."
	    SUDO='su -c'
	fi
}

PATH='/usr/local/bin:/usr/bin:/bin'
PROGNAME=$(basename "$0")
GUEST_OS=''
GUEST_NAME=''
GUEST_UUID=''
GUEST_CFG_PATH=''
MSDM_TAB='/sys/firmware/acpi/tables/MSDM'
SLIC_TAB='/sys/firmware/acpi/tables/SLIC'
DMI_TAB='/sys/firmware/dmi/tables/DMI'
DMI_TYPE0_OFFSET=0x166
DMI_TYPE1_OFFSET=0x19b
ANS=''

if [ $# -ne 1 ]; then usage; fi
if [ "$1" == '-h' ] || [ "$1" == '--help' ]; then usage; fi

declare -A VM_LIST_ARRAY
get_vm_list

if [ ${VM_LIST_ARRAY["$1"]} ]; then
	GUEST_NAME="$1"
	GUEST_UUID=${VM_LIST_ARRAY["$1"]}

	get_vm_os "$GUEST_UUID"
	res=$?

	if [ $res -eq 0 ]; then
		echo "INFO: Guest appears to be a Windows OS!"
		get_vm_cfg_dir "$GUEST_UUID"
		if [ $? -ne 0 ]; then
			echo "ERROR: CFG directory \($GUEST_CFG_PATH\) appears to not be a directory."
			exit 3
		fi
	elif [ $res -eq 1 ]; then
		echo "ERROR: Guest appears to be set for EFI Boot!"
		echo -e "\tDisable in Guest's settings via System->Motherboard->Enable EFI"
		echo -e "\tor run: vboxmanage modifyvm '$GUEST_NAME' --firmware bios"
		exit 4
	else
		echo "ERROR: Guest DOES NOT appear to be a Windows OS!"
		exit 1
	fi
else
	echo "ERROR: It appears there is no VM by the name: $1"
	exit 1
fi

echo "INFO: Guest name is: $GUEST_NAME and it's UUID is: $GUEST_UUID."
echo "INFO: The guest's conf files are located at $GUEST_CFG_PATH"

while :; do

	echo -ne "\rIs above information correct? [y/N]: "
	read -n 3 ANS
	ANS=${ANS,,}
	if [ "${ANS:0:1}" == 'y' ]; then
		break
	elif [ "${ANS:0:1}" == 'n' ]; then
		echo ""
		exit 1
	else
		echo -ne "\033[2K" # Clear terminal line
	fi
done

# Check to see if sudo is installed and if the user can run sudo commands
# If the user is unable run sudo, script falls back to su -c and will prompt for root's password
user_privs

create_guest_tables "$GUEST_CFG_PATH"
update_vm_conf "$GUEST_CFG_PATH" "$GUEST_UUID"

if [ $? -eq 0 ]; then
	echo -e "\n\nINFO: Process complete. Attempt Windows installation. If the installation prompts for "
	echo -e "\tan activation code, this script was likely unsuccessful. Confirm DMI, SLIC, and MSDM "
	echo -e "\ttable offsets on the host and correct the proper variables in this script."
else
	echo -e "\n\nERROR: It appears something may have gone wrong writing the configuration files."
	exit 1
fi

exit 0
