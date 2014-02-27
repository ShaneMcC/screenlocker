#!/bin/bash

# File to log stuff to for debugging if required, if not already specified
if [ "${SCREENLOCKER_LOGFILE}" = "" ]; then
	SCREENLOCKER_LOGFILE="/dev/null"
fi;

if [ "$_" != "/bin/bash" -a "${BASH_VERSION}" = "" ]; then
	# Not bash.
	SCREENLOCKER_ISBASH="0"

	# Make a possibly useful attempt to set BASH_SOURCE.
	# This seems to work for ksh or dash.
	if [ "${_}" = "]" -o "${0}" = "ksh" ]; then
		BASH_SOURCE="SOURCED"
	elif [ "${ZSH_VERSION}" != "" ]; then
		# Assume sourced, so that we just error out.
		BASH_SOURCE="ZSH"
	else
		BASH_SOURCE="${0}"
	fi;
else
	SCREENLOCKER_ISBASH="1"
fi;

# Check if we are actually being "sourced" or ran properly.
# If "sourced" then we just return some functions, and don't actually do
# anything.
if [ "${BASH_SOURCE}" = "${0}" ]; then
	# Make sure we are actually using bash not sh or dash
	if [ "${SCREENLOCKER_ISBASH}" != "1" ]; then
		/bin/bash $0 "${@}"
		exit $?
	fi;

	# Filename to store unlock key in.
	FILENAME=".usbkeyid"

	# Flags from below.
	# Do Setup
	SETUPMODE=0
	# Force setup even if already done
	FORCESETUP=0
	# Alternative UDEV
	ALTUDEV=0
	# Show all devices
	ALLDEVICES=0
	# Hide incompatible devices when showing all devices.
	HIDEINCOMPATIBLE=1

	while getopts huvsafik:l: OPT; do
		case "$OPT" in
			h)
				echo "USB (Un)lock v0.1"
				echo "Usage: `basename $0` [-hvsfaui] [-k keyfilename] [-l logfilename]"
				echo " -h                   This help notification"
				echo " -v                   Show version information"
				echo " -s                   Run setup process if not already completed"
				echo " -f                   Force setup to run again even if already completed (requires -s)"
				echo " -a                   When creating udev rules, use alternative syntax (If the standard rule does work. try this)"
				echo " -u                   Show all possible usb devices, not just specific 'known-good' subsets."
				echo " -i                   When using -u, show 'incompatible' devices (no serial number) rather than hiding them."
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
			i)
				HIDEINCOMPATIBLE=0
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
				SCREENLOCKER_LOGFILE="$OPTARG"
				;;
			\?)
				echo "Usage: `basename $0` [-hvs] [-f keyfilename]" >&2
				exit 1
				;;
		esac
	done
	shift `expr $OPTIND - 1`
elif [ "${SCREENLOCKER_ISBASH}" != "1" ]; then
	# Sourced, not bash.
	echo "This script requires bash."
	return;
fi;

# Find Devices
#
# First param passed will be set to contain the array of valid devices.
findDevices() {
	DEVICES=()
	while read ID; do
		if [ "${ALLDEVICES}" = "1" ]; then
			VALID=`lsusb -v -d ${ID} 2>/dev/null`
		else
			VALID=`lsusb -v -d ${ID} 2>/dev/null | egrep "(Mass Storage|Yubikey|Phone|Nexus)"`
		fi;
		if [ "${VALID}" != "" ]; then
			DEVICES+=(${ID})
		fi;
	done < <(lsusb | awk '{print $6}')

	eval $1=\"${DEVICES[*]}\"
}

# Get device location.
#
# First param passed will be set to contain the device location
# Second param passed is the actual device to look for.
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


# Show device chooser.
#
# First param will be set to the chosen device vendor
# second param will be set to the chosen device product
# third param will be set to the chosen device serial
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
				elif [ "${HIDEINCOMPATIBLE}" = "0" ]; then
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

# Set up a given device.
#
# First param will be set to the chosen device vendor
# second param will be set to the chosen device product
# third param will be set to the chosen device serial
# fourth param is the device to use based on BUS id (if fifth param is "")
# fifth param is the device to use (eg /dev/<FOO>) - if blank, BUS is used.
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

# Get the key for a given device.
#
# First param will be set to the key
# second param will be set to the chosen device vendor
# third param will be set to the chosen device product
# fourth param will be set to the chosen device serial
# fifth param is the device to use based on BUS id
# sixth param is the device to use (eg /dev/<FOO>)
# seventh param is the method to use to calculate the key.
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


# Get the key for a given device.
#
# First param will be set to the key
# second param is the device serial
# third param is the device name
# fourth param is the device vendor
# fifth param is the device product
# sixth param is the device BUS id
# seventh param is the device to use (eg /dev/<FOO>)
# eigth param is the method to use to generate the key ("1" is the only valid method)
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

# Load a key from the given file.
#
# First param will be set to the key from the file
# second param is the file to read
loadKey() {
	KEYFILE="${2}"
	if [ "${KEYFILE}" = "" ]; then
		KEYFILE="${HOME}/${FILENAME}"
	fi;
	KEY=`cat "${KEYFILE}" 2>/dev/null`
	eval ${1}=\"${KEY}\";
}

# Get a list of sessions for a user
#
# First param will be set to the array of sessions
# second param is the user to list sessions for
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

# Unlock the session of a given user.
#
# first param is the user who's sessions we want to unlock.
unlockSession() {
	USER="${1}"


	echo "---------------" >> ${SCREENLOCKER_LOGFILE} 2>&1
	echo "DATE: `date`" >> ${SCREENLOCKER_LOGFILE} 2>&1
	echo "Unlocking.." >> ${SCREENLOCKER_LOGFILE} 2>&1

	getSessions SESSIONS ${USER}
	for S in ${SESSIONS}; do
		export DISPLAY="${S}"
		echo "Display ${DISPLAY}.. " >> ${SCREENLOCKER_LOGFILE} 2>&1

		QDBUS=`which qdbus`
		DBUSSEND=`which dbus-send`
		if [ "" != "${QDBUS}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${QDBUS} org.freedesktop.ScreenSaver /ScreenSaver SetActive false" >> ${SCREENLOCKER_LOGFILE} 2>&1
		elif [ "" != "${DBUSSEND}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${DBUSSEND} --type=method_call --dest=org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver.SetActive boolean:false" >> ${SCREENLOCKER_LOGFILE} 2>&1
		fi;

		# KDE 4.10 Broke this... https://bugs.kde.org/show_bug.cgi?id=314989
		if [ "" != "${QDBUS}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${QDBUS} | grep kscreenlocker | sed 's/org.kde.//' | xargs kquitapp" >> ${SCREENLOCKER_LOGFILE} 2>&1
		elif [ "" != "${DBUSSEND}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${DBUSSEND} --print-reply --type=method_call --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames | grep kscreenlocker | awk -F\\\" '{print \$2}' | sed 's/org.kde.//' | xargs kquitapp" >> ${SCREENLOCKER_LOGFILE} 2>&1
		fi;

		echo "Unlocked" >> ${SCREENLOCKER_LOGFILE} 2>&1l
	done;
	echo "Done" >> ${SCREENLOCKER_LOGFILE} 2>&1
}


# Lock the session of a given user.
#
# first param is the user who's sessions we want to lock.
lockSession() {
	USER="${1}"

	getSessions SESSIONS ${USER}

	echo "---------------" >> ${SCREENLOCKER_LOGFILE} 2>&1
	echo "DATE: `date`" >> ${SCREENLOCKER_LOGFILE} 2>&1
	echo "Locking.." >> ${SCREENLOCKER_LOGFILE} 2>&1
	for S in ${SESSIONS}; do
		export DISPLAY="${S}"
		echo "Display ${DISPLAY}.. " >> ${SCREENLOCKER_LOGFILE} 2>&1

		# This should lock everything...
		QDBUS=`which qdbus`
		DBUSSEND=`which dbus-send`
		if [ "" != "${QDBUS}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${QDBUS} org.freedesktop.ScreenSaver /ScreenSaver Lock" >> ${SCREENLOCKER_LOGFILE} 2>&1
		elif [ "" != "${DBUSSEND}" ]; then
			su -l "${USER}" --shell="/bin/bash" -c "${DBUSSEND} --type=method_call --dest=org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver.Lock" >> ${SCREENLOCKER_LOGFILE} 2>&1
		fi;

		echo "Locked" >> ${SCREENLOCKER_LOGFILE} 2>&1
	done;
	echo "Done" >> ${SCREENLOCKER_LOGFILE} 2>&1
}


# Check if we are actually being "sourced" or ran properly.
# If "sourced" then we just wanted the functions above, otherwise we want
# to actually do something!
if [ "${BASH_SOURCE}" = "${0}" ]; then
	if [ "${SETUPMODE}" = "1" ]; then
		if [ "${FORCESETUP}" = "1" -o ! -e "${HOME}/${FILENAME}" ]; then
			choseDevice VENDOR PRODUCT SERIAL
			echo "Setup has completed."

			echo ""
			echo "To make this work, please run the following:"
			echo ""

			DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

			FLAGS=("")
			if [ "${SCREENLOCKER_LOGFILE}" != "/dev/null" ]; then
				FLAGS+=(-l ${SCREENLOCKER_LOGFILE})
			fi;
			if [ "${FILENAME}" != ".usbkeyid" ]; then
				FLAGS+=(-k "${FILENAME}")
			fi;

			# udevinfo () { udevadm info -a -p `udevadm info -q path -n "$1"`; }
			# udevinfo /dev/sdj1
			if [ "${ALTUDEV}" = "1" ]; then
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
	elif [ "${ACTION}" != "" ]; then
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
	else
		echo "USB (Un)lock v0.1"
		echo "Usage: `basename $0` [-hvsfaui] [-k keyfilename] [-l logfilename]"
		echo "Please try `basename $0` -h for help."
	fi;
fi;
