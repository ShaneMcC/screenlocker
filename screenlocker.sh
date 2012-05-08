#!/bin/bash

# Filename to store unlock key in.
FILENAME=".usbkeyid"

# File to log stuff to for debugging if required.
LOGFILE="/dev/null"

# Flags from below.
# Do Setup
SETUPMODE=0
# Force setup even if already done
FORCESETUP=0

while getopts hvsfk:l: OPT; do
	case "$OPT" in
		h)
			echo "USB (Un)lock v0.1"
			echo "Usage: `basename $0` [-hvsf] [-k keyfilename] [-l logfilename]"
			echo " -h                   This help notification"
			echo " -v                   Show version information"
			echo " -s                   Run setup process if not already completed"
			echo " -f                   Force setup to run again even if already completed (requires -s)"
			echo " -k <keyfilename>     Specify an alternative key file to use"
			echo " -l <logfilename>     Specify a log file name"
			exit 0
			;;
		v)
			echo "USB (Un)lock v0.1"
			exit 0
			;;
		s)
			SETUPMODE=1
			;;
		f)
			FORCESETUP=1
			;;
		k)
			FILENAME="$OPTARG"
			;;
		l)
			LOGFILE="$OPTARG"
			;;
		\?)
			echo "Usage: `basename $0` [-hvs] [-f keyfilename]" >&2
			exit 1
			;;
	esac
done
shift `expr $OPTIND - 1`

findDevices() {
	DEVICES=()
	while read ID; do
		VALID=`lsusb -v -d ${ID} 2>/dev/null | grep "Mass Storage"`
		if [ "${VALID}" != "" ]; then
			DEVICES+=(${ID})
		fi;
	done < <(lsusb | awk '{print $6}')

	eval $1=\"${DEVICES[*]}\"
}

getDeviceLocation() {
	DEVICE=${2}
	VENDOR=`echo ${DEVICE} | awk -F: '{print $1}'`
	PRODUCT=`echo ${DEVICE} | awk -F: '{print $2}'`

	LOCATIONS=()
	while read BUS; do
		ISVENDOR=`grep ${VENDOR} /sys/bus/usb/devices/${BUS}/idVendor`
		if [ "${VENDOR}" != "" ]; then
			LOCATIONS+=(${BUS})
		fi;
	done < <(grep ${PRODUCT} /sys/bus/usb/devices/*/idProduct | awk -F/ '{print $6}')

	eval $1=\"${LOCATIONS[*]}\"
}


choseDevice() {
	findDevices DEVICES

	echo "The following devices have been found: "
	echo ""

	COUNT=0
	declare -A DEVS

	for D in ${DEVICES}; do
		getDeviceLocation LOCATIONS ${D}
		for BUS in "${LOCATIONS[@]}"; do
			SERIAL=`cat /sys/bus/usb/devices/${BUS}/serial`
			NAME=`cat /sys/bus/usb/devices/${BUS}/product`

			LISTED=0
			while read BLOCK; do
				DEV=`ls ${BLOCK} | head -n 1`
				while read PART; do
					if [ ${LISTED} = '0' ]; then
						echo ""
						echo "  ${NAME}: ${SERIAL} (${BUS})"
					fi;
					LISTED=1

					echo "    ${COUNT}: /dev/${PART}"
					DEVS["${COUNT},DEV"]="${DEV}"
					DEVS["${COUNT},BUS"]="${BUS}"
					COUNT=$((${COUNT} + 1))
				done < <(ls -1 ${BLOCK}/${DEV}/ | grep ^${DEV})
			done < <(find /sys/bus/usb/devices/${BUS}/ -name block)
		done
	done;

	echo ""
	echo -n "Please pick a block device number to use: "
	read number

	echo ""
	DEV=${DEVS["${number},DEV"]}
	BUS=${DEVS["${number},BUS"]}

	if [ "${DEV}" = "" ]; then
		echo "No (valid) device selected." >&2
		exit 1;
	fi;

	setupDevice VENDOR PRODUCT SERIAL "${BUS}" "${DEV}"

	eval ${1}=\"${VENDOR}\"
	eval ${2}=\"${PRODUCT}\"
	eval ${3}=\"${SERIAL}\"
}

setupDevice() {
	BUS="${4}"
	DEV="${5}"

	echo ""
	echo "Setting up with /dev/${DEV}..."
	getDeviceKey KEY VENDOR PRODUCT SERIAL "${BUS}" "${DEV}"

	echo ${KEY} > "${HOME}/${FILENAME}"
	eval ${1}=\"${VENDOR}\"
	eval ${2}=\"${PRODUCT}\"
	eval ${3}=\"${SERIAL}\"
}

getDeviceKey() {
	BUS="${5}"
	DEV="${6}"
	METHOD="${7}"

	SERIAL=`cat /sys/bus/usb/devices/${BUS}/serial`
	NAME=`cat /sys/bus/usb/devices/${BUS}/product`
	VENDOR=`cat /sys/bus/usb/devices/${BUS}/idVendor`
	PRODUCT=`cat /sys/bus/usb/devices/${BUS}/idProduct`

	makeKey KEY "${SERIAL}" "${NAME//[ ]/_}" "${VENDOR}" "${PRODUCT}"
	eval ${1}=\"${KEY}\";
	eval ${2}=\"${VENDOR}\";
	eval ${3}=\"${PRODUCT}\";
	eval ${4}=\"${SERIAL}\";
}

makeKey() {
	SERIAL="${2}"
	NAME="${3}"
	VENDOR="${4}"
	PRODUCT="${5}"

	# Meh.
	if [ "${METHOD}" = "1" -o "${METHOD}" = "" ]; then
		KEY1=`echo "${SERIAL}${NAME}" | md5sum - | awk -F\  '{print $1}'`
		KEY2=`echo "${NAME}" | md5sum - | awk -F\  '{print $1}'`
		KEY3=`echo "${SERIAL}"`
		KEY5=`echo "${VENDOR}${PRODUCT}" | md5sum - | awk -F\  '{print $1}'`
		KEY4=`sha1pass "${SERIAL}" "${KEY5}"`
		KEY4="${KEY4//[^A-Za-z0-9]/}"

		KEY="1|${KEY1}#${KEY2}${KEY3}${KEY4}#${KEY5}"
	else
		KEY="0|0"
	fi;

	KEY="${KEY}|"`echo "${KEY}" | md5sum - | awk -F\  '{print $1}'`
	eval ${1}=\"${KEY}\";
}

loadKey() {
	KEYFILE="${2}"
	if [ "${KEYFILE}" = "" ]; then
		KEYFILE="${HOME}/${FILENAME}"
	fi;
	KEY=`cat "${KEYFILE}"`
	eval ${1}=\"${KEY}\";
}

getSessions() {
	USER="${2}"
	ID=`id -u ${USER}`

	SESSIONS=$(ck-list-sessions | awk -F' = ' '
		function f(){if(U!="'${ID}'"){gsub("'"'"'","",D);print D}}
		$1=="\tunix-user"{U=$2}
		$1=="\tx11-display"{D=$2}
		END{f()} /^[^\t]/{f()}
	')

	eval $1=\"${SESSIONS}\"
}

unlockSession() {
	USER="${1}"


	echo "---------------" >> ${LOGFILE} 2>&1
	echo "DATE: `date`" >> ${LOGFILE} 2>&1
	echo "Unlocking.." >> ${LOGFILE} 2>&1

	getSessions SESSIONS ${USER}
	for S in ${SESSIONS}; do
		export DISPLAY="${S}"
		echo "Display ${DISPLAY}.. " >> ${LOGFILE} 2>&1
		# KDE
		su -l "${USER}" --shell="/bin/bash" -c "killall kscreenlocker" >> ${LOGFILE} 2>&1

		# Gnome


		echo "Unlocked" >> ${LOGFILE} 2>&1l
	done;
	echo "Done" >> ${LOGFILE} 2>&1
}

lockSession() {
	USER="${1}"

	getSessions SESSIONS ${USER}

	echo "---------------" >> ${LOGFILE} 2>&1
	echo "DATE: `date`" >> ${LOGFILE} 2>&1
	echo "Locking.." >> ${LOGFILE} 2>&1
	for S in ${SESSIONS}; do
		export DISPLAY="${S}"
		echo "Display ${DISPLAY}.. " >> ${LOGFILE} 2>&1
		# This should lock everything...
		su -l "${USER}" --shell="/bin/bash" -c "qdbus org.freedesktop.ScreenSaver /ScreenSaver Lock" >> ${LOGFILE} 2>&1
		echo "Unlocked" >> ${LOGFILE} 2>&1
	done;
	echo "Done" >> ${LOGFILE} 2>&1
}

if [ "${SETUPMODE}" = "1" ]; then
	if [ "${FORCESETUP}" = "1" -o ! -e "${HOME}/${FILENAME}" ]; then
		choseDevice VENDOR PRODUCT SERIAL
		echo "Setup has completed."

		echo ""
		echo "To make this work, please run the following as root:"
		echo ""

		DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

		FLAGS=("")
		if [ "${LOGFILE}" != "/dev/null" ]; then
			FLAGS+=(-l ${LOGFILE})
		fi;
		if [ "${FILENAME}" != ".usbkeyid" ]; then
			FLAGS+=(-k "${FILENAME}")
		fi;

		echo "echo 'SUBSYSTEMS==\"usb\", ATTRS{idVendor}==\"${VENDOR}\" ATTRS{idProduct}==\"${PRODUCT}\", ATTRS{serial}==\"${SERIAL}\", RUN+=\"${DIR}/`basename ${0}`${FLAGS[@]}\"' >> /etc/udev/rules.d/80-usbdisk.rules"
		echo "chmod a+x /etc/udev/rules.d/80-usbdisk.rules"
		echo "restart udev"
	else
		echo "Setup has already been completed."
	fi;
	exit 0;
else
	# Called by udev.

	if [ "${ACTION}" = "add" -a "${ID_VENDOR_ID}" != "" -a "${ID_MODEL_ID}" != "" -a "${DEVNAME}" != ""  ]; then
		VENDOR="${ID_VENDOR_ID}"
		PRODUCT="${ID_MODEL_ID}"
		SERIAL="${ID_SERIAL_SHORT}"
		NAME="${ID_MODEL}"

		while read KEYFILE; do
			loadKey KEYWANTED "${KEYFILE}"
			USER=`stat -c %U "${KEYFILE}"`
			METHOD=`echo ${KEYWANTED} | awk -F\| '{print $1}'`

			makeKey KEY "${SERIAL}" "${NAME}" "${VENDOR}" "${PRODUCT}" "${METHOD}"

			if [ "${KEY}" = "${KEYWANTED}" ]; then
				unlockSession ${USER}
			fi;
		done < <(ls /home/*/${FILENAME});
	elif [ "${ACTION}" = "remove" -a "${ID_VENDOR_ID}" != "" -a "${ID_MODEL_ID}" != "" -a "${DEVNAME}" != ""  ]; then
		VENDOR="${ID_VENDOR_ID}"
		PRODUCT="${ID_MODEL_ID}"
		SERIAL="${ID_SERIAL_SHORT}"
		NAME="${ID_MODEL}"

		while read KEYFILE; do
			loadKey KEYWANTED "${KEYFILE}"
			USER=`stat -c %U "${KEYFILE}"`
			METHOD=`echo ${KEYWANTED} | awk -F\| '{print $1}'`

			makeKey KEY "${SERIAL}" "${NAME}" "${VENDOR}" "${PRODUCT}" "${METHOD}"

			if [ "${KEY}" = "${KEYWANTED}" ]; then
				GOTKEY="1"
				lockSession ${USER}
			fi;
		done < <(ls /home/*/${FILENAME});
	fi;
fi