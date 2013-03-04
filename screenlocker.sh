#!/bin/bash

# Make sure we are actually using bash not sh or dash
if [ "$_" != "/bin/bash" ]; then
	/bin/bash $0 "${@}"
	exit $?
fi;

# Filename to store unlock key in.
FILENAME=".usbkeyid"

# File to log stuff to for debugging if required.
LOGFILE="/dev/null"

# Flags from below.
# Do Setup
SETUPMODE=0
# Force setup even if already done
FORCESETUP=0
# Alternative UDEV
ALTUDEV=0
# Alternative UDEV
ALLDEVICES=0

while getopts huvsafk:l: OPT; do
	case "$OPT" in
		h)
			echo "USB (Un)lock v0.1"
			echo "Usage: `basename $0` [-hvsf] [-k keyfilename] [-l logfilename]"
			echo " -h                   This help notification"
			echo " -v                   Show version information"
			echo " -s                   Run setup process if not already completed"
			echo " -f                   Force setup to run again even if already completed (requires -s)"
			echo " -a                   When creating udev rules, use alternative syntax (If the standard rule does work. try this)"
			echo " -u                   Show all possible usb devices, not just specific 'known-good' subsets. [EXPERIMENTAL]"
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
		a)
			ALTUDEV=1
			;;
		u)
			ALLDEVICES=1
			;;
		k)
			FILENAME="$OPTARG"
			DIR=`dirname ${FILENAME}`
			if [ ! -e "${HOME}/${DIR}" ]; then
				echo "ERROR: Filename is relative to current home directory, not an absolute path." >&2
				exit 1;
			fi;
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
		if [ "${ALLDEVICES}" = "1" ]; then
			VALID=`lsusb -v -d ${ID} 2>/dev/null`
		else
			VALID=`lsusb -v -d ${ID} 2>/dev/null | egrep "(Mass Storage|Yubikey|Phone)"`
		fi;
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

	COMPATIBLE=0
	for D in ${DEVICES}; do
		getDeviceLocation LOCATIONS ${D}
		for BUS in "${LOCATIONS[@]}"; do
			SERIAL=`cat /sys/bus/usb/devices/${BUS}/serial 2>/dev/null`
			NAME=`cat /sys/bus/usb/devices/${BUS}/product 2>/dev/null`

			LISTED=0
			ISBLOCK=0
			# Check block devices.
			while read BLOCK; do
				ISBLOCK=1
				DEV=`ls ${BLOCK} | head -n 1`
				while read PART; do
					if [ ${LISTED} = '0' ]; then
						echo ""
						echo "  ${NAME}: ${SERIAL} (${BUS})"
					fi;
					LISTED=1

					printf "    %3d: /dev/%s\n" "${COUNT}" "${PART}"
					COMPATIBLE=1
					DEVS["${COUNT},DEV"]="${DEV}"
					DEVS["${COUNT},BUS"]="${BUS}"
					COUNT=$((${COUNT} + 1))
				done < <(ls -1 ${BLOCK}/${DEV}/ | grep ^${DEV})
			done < <(find /sys/bus/usb/devices/${BUS}/ -name block 2>/dev/null)

			# Check non-block devices, eg hardware tokens (yubikey)
			if [ "${ISBLOCK}" != "1" ]; then
				if [ "${SERIAL}" != "" ]; then
					echo ""
					echo "  ${NAME}: ${SERIAL} (${BUS})"
					LISTED=1
					printf "    %3d: %s\n" "${COUNT}" "${NAME}"
					DEVS["${COUNT},DEV"]=""
					DEVS["${COUNT},BUS"]="${BUS}"
					COUNT=$((${COUNT} + 1))
					COMPATIBLE=1
				else
					echo ""
					echo "  ${NAME}: ${SERIAL} (${BUS})"
					printf "         %s\n" "This device is not compatible (no serial number found)"
				fi;
			fi;
		done
	done;

	echo ""

	if [ "${COMPATIBLE}" != "1" ]; then
		echo "Error: No valid devices found." >&2
		exit 1;
	fi;

	echo -n "Please pick a device number to use: "
	read number

	echo ""
	DEV=${DEVS["${number},DEV"]}
	BUS=${DEVS["${number},BUS"]}

	if [ "${BUS}" = "" ]; then
		echo "Error: No (valid) device selected." >&2
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
	if [ "" = "${DEV}" ]; then
		echo "Setting up with device in BUS ${BUS}..."
	else
		echo "Setting up with /dev/${DEV}..."
	fi;
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

	SERIAL=`cat /sys/bus/usb/devices/${BUS}/serial 2>/dev/null`
	NAME=`cat /sys/bus/usb/devices/${BUS}/product 2>/dev/null`
	VENDOR=`cat /sys/bus/usb/devices/${BUS}/idVendor 2>/dev/null`
	PRODUCT=`cat /sys/bus/usb/devices/${BUS}/idProduct 2>/dev/null`

	makeKey KEY "${SERIAL}" "${NAME//[ ]/_}" "${VENDOR}" "${PRODUCT}" "${BUS}" "${DEV}" "${METHOD}"
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
	BUS="${6}"
	DEV="${7}"
	METHOD="${8}"

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
	KEY=`cat "${KEYFILE}" 2>/dev/null`
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

		QDBUS=`which qdbus`
		DBUSSEND=`which dbus-send`
		if [ "" != "${QDBUS}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${QDBUS} org.freedesktop.ScreenSaver /ScreenSaver SetActive false" >> ${LOGFILE} 2>&1
		elif [ "" != "${DBUSSEND}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${DBUSSEND} --type=method_call --dest=org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver.SetActive boolean:false" >> ${LOGFILE} 2>&1
		fi;

		# KDE 4.10 Broke this... https://bugs.kde.org/show_bug.cgi?id=314989
		if [ "" != "${QDBUS}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${QDBUS} | grep kscreenlocker | sed 's/org.kde.//' | xargs kquitapp" >> ${LOGFILE} 2>&1
		elif [ "" != "${DBUSSEND}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${DBUSSEND} --print-reply --type=method_call --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames | grep kscreenlocker | awk -F\\\" '{print \$2}' | sed 's/org.kde.//' | xargs kquitapp" >> ${LOGFILE} 2>&1
		fi;

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
		QDBUS=`which qdbus`
		DBUSSEND=`which dbus-send`
		if [ "" != "${QDBUS}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${QDBUS} org.freedesktop.ScreenSaver /ScreenSaver Lock" >> ${LOGFILE} 2>&1
		elif [ "" != "${DBUSSEND}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${DBUSSEND} --type=method_call --dest=org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver.Lock" >> ${LOGFILE} 2>&1
		fi;

		echo "Locked" >> ${LOGFILE} 2>&1
	done;
	echo "Done" >> ${LOGFILE} 2>&1
}

if [ "${SETUPMODE}" = "1" ]; then
	if [ "${FORCESETUP}" = "1" -o ! -e "${HOME}/${FILENAME}" ]; then
		choseDevice VENDOR PRODUCT SERIAL
		echo "Setup has completed."

		echo ""
		echo "To make this work, please run the following:"
		echo ""

		DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

		FLAGS=("")
		if [ "${LOGFILE}" != "/dev/null" ]; then
			FLAGS+=(-l ${LOGFILE})
		fi;
		if [ "${FILENAME}" != ".usbkeyid" ]; then
			FLAGS+=(-k "${FILENAME}")
		fi;

		# udevinfo () { udevadm info -a -p `udevadm info -q path -n "$1"`; }
		# udevinfo /dev/sdj1
		if [ "${ALTUDEV}" == "1" ]; then
			echo -n "echo 'SUBSYSTEMS==\"usb\", ENV{ID_VENDOR_ID}==\"${VENDOR}\" ENV{ID_MODEL_ID}==\"${PRODUCT}\", ENV{ID_SERIAL_SHORT}==\"${SERIAL}\""
		else
			echo -n "echo 'SUBSYSTEMS==\"usb\", ATTRS{idVendor}==\"${VENDOR}\" ATTRS{idProduct}==\"${PRODUCT}\", ATTRS{serial}==\"${SERIAL}\""
		fi;
		echo -n ", RUN+=\"${DIR}/`basename ${0}`${FLAGS[@]}\"' | sudo tee -a /etc/udev/rules.d/80-usbdisk.rules";

		echo -n "; sudo chmod a+x /etc/udev/rules.d/80-usbdisk.rules"
		echo "; sudo restart udev"
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
