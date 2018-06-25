#!/bin/bash

# mass_configure_alarm.sh
#
# This script can configure alarms base on a  matrix containing IPS devices
# IP address and alarm configuration values. See help text (--help) for more.
#
# Copyright (C) 2018, Riedo Networks Ltd
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
#
#
# Change log
# ----------
#
#  - 20.06.2018: Initial release
#

### Global variables ##########################################################

TIMEOUT=1
ALARM_FORMAT_RE='^[0-9]{1,2}([.][0-9]{1,2})?$'

#################### FUNCTIONS #######################

# Function to send & upgrade the firmware.
# Argument 1: IPS's IP address
# Argument 2: Firmware file
function send_fw()
{
	local IP=$1
	local FW_BIN=$2

	curl -\# -o /dev/null --basic -u admin:admin -F fw=@$FW_BIN http://$IP/maintenance
}


function do_ips_command()
{
	local IP="$1"
	local CMD="$2"
	local LOG=$(expect << EOF
	set ip_addr [lindex $argv 0]
	spawn telnet $IP

	expect "Username:"
	send "admin\r"
	expect "Password:"
	send "admin\r"
	expect ">"
	send "$CMD\r"
	expect ">"
	send "exit\r"

EOF
	)
	echo "$LOG"

}

function do_ips_command_check()
{
	LOG=$(do_ips_command "$1" "$2")
	echo $LOG | grep "Command failed"
	if [ $? -eq 0 ]
	then
		echo "Warning: Command \"$2\" Failed !"
		#echo "LOG=\"$LOG\""
		return 1
	fi
	return 0
}


function get_version()
{
	local IP=$1
	echo "$(do_ips_command $IP "show version")" \
		| sed -n -E -e 's/^Firmware:\s([0-9]*\.[0-9]*)/\1/p' \
		| tr -dc '[[:print:]]'
}

function get_build()
{
	local IP=$1
	echo "$(do_ips_command $IP "show version")" \
		| sed -n -E -e 's/^Build:\s([0-9a-f]*)/\1/p' \
		| tr -dc '[[:print:]]'
}

function get_model()
{
	local IP=$1
	echo "$(do_ips_command $IP "show version")" \
		| sed -n -E -e 's/^Model:\s([0-9]*)/\1/p' \
		| tr -dc '[[:print:]]'
}

function get_serial()
{
	local IP=$1
	echo "$(do_ips_command $IP "show version")" \
		| sed -n -E -e 's/^Serial:\s([0-9]*)/\1/p' \
		| tr -dc '[[:print:]]'
}

function get_label()
{
	local IP=$1
	echo "$(do_ips_command $IP "show conf")" \
		| sed -n -E -e 's/^device_label\s+(.*)/\1/p' \
		| tr -dc '[[:print:]]'
}

function is_online()
{
	local IP=$1
	#nc -v -z -w $TIMEOUT $IP 80 
	NC_TEXT=$(nc -v -z -w $TIMEOUT $IP 80 2>&1)
	#echo "$NC_TEXT" 
	echo "$NC_TEXT" | grep 'Connection refused\|succeeded' > /dev/null || return 1
	return 0
}

function wait_online()
{
	sleep 3
	while ! is_online $1 ; do
		printf "."
	done
}

# Probe if given address is an IPS
# Argument 1: Device access
# Return 0 if device is an IPS
function probe_ips()
{
	# Let's consider that an IPS is an node that offers HTTP, Telnet and SNMP
	local IP=$1

	# Test UPD port 161: SNMP
	nc -zu -w $TIMEOUT $IP 161 || return 1
	
	# Test TCP port 80: HTTP
	nc -z -w $TIMEOUT $IP 80 || return 1

	# Test that we can get the "/about" page and that it contains "E3METER" somewhere
	curl -4 http://$IP/about 2>/dev/null | grep E3METER > /dev/null || return 1

	# Test TCP port 23: Telent
	nc -z -w $TIMEOUT $IP 23 || return 1

	return 0
}

# Convert an IPv4 address in WWW.XXX.YYY.ZZZ format to decimal number-
# Argument 1: IP address in "dot notation"
# Return decimal number
function ip2d()
{
	IFS=.
	set -- $*
	echo $(( ($1*256**3) + ($2*256**2) + ($3*256) + ($4) ))
}

# Convert an decimal number to IPv4 address in WWW.XXX.YYY.ZZZ format-
function  d2ip()
{
	IFS=" " read -r a b c d  <<< $(echo  "obase=256 ; $1" |bc)
	echo ${a#0}.${b#0}.${c#0}.${d#0}
}

function check_version()
{
	# Argument 1 is minimum required version
	# Argument 2 is given version
	local MIN_VER
	local GIVEN_VER
	IFS='.' read -ra MIN_VER <<< "$1"
	IFS='.' read -ra GIVEN_VER <<< "$2"

	#echo "${GIVEN_VER[@]}"
	#echo "${MIN_VER[@]}"
	local i
	for i in "${!GIVEN_VER[@]}"
	do 
		if [ "${GIVEN_VER[$i]}" -lt ${MIN_VER[$i]} ]
		then
			#echo "${GIVEN_VER[$i]} smaller than ${MIN_VER[$i]}, failed"
			return 1
		#else
			#echo echo "${GIVEN_VER[$i]} greater or equal than ${MIN_VER[$i]}, OK"
		fi
	done
	return 0
}

function usage() {
	echo "Usage: $ME [-h] CONFIG_FILE.CSV"
	echo ""
	echo " Configure alarms on IPSs"
	echo ""
	echo "Do a batch/mass alarm configuration. IPS devices are accessed trough TCP/IP/Ethernet. IPS devices are referenced by they IP addresses. " | fold -s
	echo ""
	echo "The list of devices ant they configuration is given by a CSV file. In this CSV file, the first column is the IP address. If the first column is empty the line is discarded. The two first lines must contains headers. The first line contains the channel name. The second line contains the alarm level to set. Every other cell contains alarm configuration value that is matched to its line or column. The line gives the address (first column) and the column gives the channel and alarm name. Alarm level are real number with maximum two decimal places." | fold -s
	echo ""
	echo "To help creating the configuration CSV file, the LibreOffice Calc document \"alarm_template.ods\" is provided. When exporting to CSV, make sure not to check \"Quote all text cells\" and to use the semi-column as field delimiter." | fold -s
	echo ""
	echo "Options:"
	echo "  -h, --help        Display this help and exit"
}

CHANNEL_LIST=(
	"current_l1"
	"current_l2"
	"current_l3"
	"temp_int"
	"temp_ext1"
	"temp_ext2"
	"rh_ext1"
	"rh_ext2"
)

ALARM_LIST=(
	"lo_crit"
	"lo_warn"
	"hi_warn"
	"hi_crit"
)


### MAIN ######################################################################



### Parse argument
ME=$0
while [ "$1" != "" ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "invalid option '$1'" >&2 
            usage
            exit 1
            ;;
        *)
			POS_ARGS+=($1)
			;;
    esac
    shift
done

# Check arguments
if [ ${#POS_ARGS[*]} == 0 ]
then
	echo "Configuration file missing. See \"$ME -h\" for help."
	exit 1
elif (( ${#POS_ARGS[*]} > 1 ))
then
	echo "Too many arguments. See \"$ME -h\" for help."
	exit 1
fi


# Get the positional arguments
CONFIG="${POS_ARGS[0]}"

# Check that the configuration file exists
if [ ! -f "$CONFIG" ]
then
	echo "ERROR: No such file : \"$CONFIG\""
	exit 1
fi

# For each line in the file...
i=0
SUCESS=0
OFFLINES=0
BAD_VERION=0
BAD_VALUE=0
REMOTE_ERROR=0
while read line
do
	i=$(($i+1))

	if (( i == 1))
	then
		# First line contains channels names
		IFS=',' read -r -a CHANNELS <<< "$line"
	elif (( i == 2))
	then
		# Second lines contains alarms names
		IFS=',' read -r -a ALARMS <<< "$line"
	else
		# All other lines contains alarm data
		IFS=',' read -r -a DATA <<< "$line"
		IP=${DATA[0]}

		# Check that the device is on-line
		if ! is_online $IP 
		then
			echo "WARNING: Device at \"$IP\" is off-line (does not respond) !\""
			OFFLINES=$(($OFFLINES+1))
			continue
		fi

		# Check that the device has a version greater than 4.2 (first release with alarms)
		VERSION=$(get_version $IP)
		MINIMUM_VERSION="4.2"
		if  ! check_version "$MINIMUM_VERSION" "$VERSION"
		then
			echo "WARNING: IPS \"$(get_label $IP)\" at \"$IP\" has unsupported firmware version (found \"$VERSION\", expected \">$MINIMUM_VERSION\"). Skipped." 
			BAD_VERION=$(($BAD_VERION+1))
			continue
		fi

		echo -n "Configuring $IP..."

		CMD="set alarm "

		# Iterate the possible channel list
		for sChannel in "${CHANNEL_LIST[@]}"
		do
			# Command template
			CMD="set alarm $sChannel"
			#  Iterate the possible alarm list
			for sAlarm in "${ALARM_LIST[@]}"
			do
				# Alarm set-point
				SET="na"

				# Iterate the configuration
				for c_chan_indx in "${!CHANNELS[@]}"
				do
					cChannel="${CHANNELS[$c_chan_indx]}"
					cAlarm="${ALARMS[$c_chan_indx]}"

					# Match the configuration channel & alarm with the static list
					if [ "$cChannel" == "$sChannel" ]  && [ "$cAlarm" == "$sAlarm" ]
					then
						DATA_VAL="${DATA[$c_chan_indx]}"

						
						if [ ! -z "$DATA_VAL" ]
						then
							# Check that the data is a real number
							if [[ $DATA_VAL =~ $ALARM_FORMAT_RE
						 ]] 
							then
								SET="$DATA_VAL"
							else
								echo "WARNING: Bad value \"$DATA_VAL\" for \"$cChannel $cAlarm\", not set."
								BAD_VALUE=$(($BAD_VALUE+1))
								SUCESS=$(($SUCESS-1))
							fi
						fi
					fi
				done
				CMD="$CMD $SET"
			done
			#echo $CMD
			if ! do_ips_command_check "$IP" "$CMD"
			then
				REMOTE_ERROR=$(($REMOTE_ERROR+1))
				SUCESS=$(($SUCESS-1))
			fi

		done

		# save configuration
		do_ips_command_check $IP "conf save"
		do_ips_command $IP "reboot" > /dev/null
		echo "Done"
		SUCESS=$(($SUCESS+1))
	fi

done < "$CONFIG"

TOTAL_IPS=$(($i-2))

# Print the resume
echo
echo "$SUCESS/$TOTAL_IPS IPS(s) devices configured with success"
if [ "$OFFLINES" -gt "0" ]
then
	echo "$OFFLINES IPS(s) devices were off-line!"
fi
if [ "$BAD_VERION" -gt "0" ]
then
	echo "$BAD_VERION IPS(s) devices had unsupported firmware version!"
fi
if [ "$BAD_VALUE" -gt "0" ]
then
	echo "$BAD_VALUE Configuration setting had bad value in them!"
fi
if [ "$REMOTE_ERROR" -gt "0" ]
then
	echo "$REMOTE_ERROR IPS(s) devices reported an error!"
fi

exit 0
