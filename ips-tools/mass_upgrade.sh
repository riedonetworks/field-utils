#!/bin/bash

# mass_upgrade.sh
#
# (c) 2018, Riedo Networks, Antoine Zen-Ruffinen <antoine@riedonetworks.com>
#
# This script has can do mass upgrade of IPS devices. See help text for more information
#
# mass_upgrade.sh is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Ansible is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Ansible.  If not, see <http://www.gnu.org/licenses/>.

########################################################
# Change log:
#  - 20.02.2018: Initial release
########################################################

### Global variables ##########################################################

RANGE_START=""
RANGE_END=""
IP_LIST_FILE=""
TIMEOUT=1

#################### FUNCTIONS #######################

# Function to send & updrade the FW.
# Arg 1: IPS's IP address
# Arg 2: Fiwmare file
function send_fw()
{
	local IP=$1
	local FW_BIN=$2

	curl -\# -o /dev/null --basic -u admin:admin -F fw=@$FW_BIN http://$IP/maintenance
}


function do_ips_command()
{
	local IP=$1
	local CMD=$2
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

# Convert an IPv4 addres in WWW.XXX.YYY.ZZZ format to decimal number-
# Arument 1: IP address in "dot notation"
# Return decimal number
function ip2d()
{
	IFS=.
	set -- $*
	echo $(( ($1*256**3) + ($2*256**2) + ($3*256) + ($4) ))
}

# Convert an decimal number to IPv4 addres in WWW.XXX.YYY.ZZZ format-
function  d2ip()
{
	IFS=" " read -r a b c d  <<< $(echo  "obase=256 ; $1" |bc)
	echo ${a#0}.${b#0}.${c#0}.${d#0}
}

function usage() {
	echo "Usage: $ME [-r|--range START_IP END_IP] [-f|--file IP_LIST_FILE] [-t TIMEOUT] [FIRMWARE_FILE] [2.7_FIRMWARE_FILE]"
	echo ""
	echo " Upgrade IPS in mass or query version"
	echo ""
	echo "Does a batch/mass upgrade of IPS device or display the firwmare version of IPS devices. IPS devices are accessed trough TCP/IP/Ethernet. IPS devices are referenced by they IP addresses. "
	echo ""
	echo "The list of devices to upgrade/query is ether given by a file ('-f' option) or by a range ('-r' option). The file ('-f' option) must contains one IP address per line. If the range is given ('r' option), the first address and the last address of the range must be provided. They can be blank address within the range."
	echo ""
	echo "Without the '-u' flag, the script will display the following informations for each devices:"
	echo " - Model"
	echo " - Serial Numer"
	echo " - Firmware version and build number"
	echo " - Label"
	echo ""
	echo "If a firwmare file is provided, the script will perform an upgrade of the devices within the list or range."
	echo ""
	echo "If a device has a firmware older than v2.1, then it must be upgraded to v2.7 before newer version (v2.1 can be upgraded to the latest version). In that case, the v2.7 firmware must be given after target fiwmare."
	echo ""
	echo "Options:"
	echo "  -r, --range		  Specify the IP address range"
	echo "  -f, --file        Specify a file containing one IP addres per line"
	echo "  -t, --timeout     Specify connection timeout (default=$TIMEOUT seconds)"
	echo "  -u, --upgrade     Upgrade listed IPS. Default is display the fiwmare version."
	echo "  -h, --help        Display this help and exit"
}



### MAIN ######################################################################

### Parse argument
ME=$0
while [ "$1" != "" ]; do
    case "$1" in
        -r|--range)
            shift
            RANGE_START="$1"
            shift
            RANGE_END="$1"
            ;;
        -f|--file)
            shift
            IP_LIST_FILE="$1"
            ;;
        -t|--timeout)
            shift
            TIMEOUT="$1"
            ;;
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

### Get the list of IP address out of the list in the file or from the range

declare -a IP_LIST
if [ ! -z $IP_LIST_FILE ]; then
	echo "Using IP list file $IP_LIST_FILE"
	readarray -t IP_LIST < $IP_LIST_FILE
elif [ ! -z $RANGE_START ]  && [ ! -z $RANGE_END ]; then
	echo "Using IP range $RANGE_START -> $RANGE_END"
	for i in $(seq $(ip2d $RANGE_START) $(ip2d $RANGE_END))
	do
	    IP_LIST+=("$(d2ip $i)")
	    #IP_LIST=("$IP_LIST" "$(d2ip $i)")
	done
else
	echo "No range or file provied (use \"$0 --help\" for help)"
	exit 1
fi

#echo "IP_LIST=${IP_LIST[@]}"


if [ ${#POS_ARGS[@]} -gt "0" ]; then

	echo "Upgrade"
	# Get firmwares
	FW_FILE=$(readlink -f "${POS_ARGS[0]}")
	FW_FILE_VERSION=$(echo "$FW_FILE" | sed -n -E -e "s/.*ips2_r([0-9]\.[0-9])(-DEV)?_[0-9a-f]+_[0-9]*.bin/\1/p")

	# Find the transition firmware
	TRANSITION_FW_FILE=$(readlink -f "${POS_ARGS[1]}")
	TRANSITION_VERSION="2.3"

	echo "Upgrading using FW \"$FW_FILE\" which contains version $FW_FILE_VERSION."
	echo "Transition FW : $TRANSITION_FW_FILE"
	
	for IP in ${IP_LIST[@]}
	do
		# Print the device IP
		#printf "Upgrading %16s ...\n" $IP

		# Is the device online (reachable) ?
		if [ -z $IP_LIST_FILE ]; then
			printf "$IP: "
		fi
		if is_online $IP ; then
			#Is it an IPS ?
			if probe_ips $IP; then
				IPS_VERSION="$(get_version $IP)"
				IPS_LABEL="$(get_label $IP)"

				# Is the FW older than 2.7? 
				if [[ "$IPS_VERSION" < "$TRANSITION_VERSION" ]]; then
					# Check that we have the firmware
					if [ -z "$TRANSITION_FW_FILE" ]; then
						echo "WARNING: IPS \"$IPS_LABEL\" at $IP need to be upgraded first to $TRANSITION_VERSION but fiwmare file is missing!"
						continue
					fi
					# Upgrade to 2.7
					echo "Upgradeing IPS \"$IPS_LABEL\" at $IP from version $IPS_VERSION to $TRANSITION_VERSION..."
					send_fw $IP $TRANSITION_FW_FILE

					# Wait to be back online
					wait_online $IP
					echo

					# Get the version for the next step.
					IPS_VERSION="$(get_version $IP)"
				fi

				# Is the version older that the most up-to-date firmware available ?
				if [[ "$IPS_VERSION" != "$FW_FILE_VERSION" ]]; then
					# Upgrade
					echo "Upgradeing IPS \"$IPS_LABEL\" at $IP from version $IPS_VERSION to $FW_FILE_VERSION..."
					send_fw $IP $FW_FILE
				else
					# Tell the user that the device is fine!
					echo "IPS \"$IPS_LABEL\" at $IP is up-to-date (v$FW_FILE_VERSION)!"
				fi
				
			elif [ ! -z $IP_LIST_FILE ]; then
				# If the IP are getted from the file, display the status
				echo "Device at $IP is not an IPS!" 
			else
				printf "\r"
			fi
		elif [ ! -z $IP_LIST_FILE ]; then
			# If the IP are getted from the file, display the status
			echo "Device at $IP seems to be offline!" 
		else
			printf "\r"
		fi
	done

	exit 0
else

	### Query and print FW informations

	LINE_SEP="+------------------+--------+--------+-----------------+------------------+"
	echo
	echo $LINE_SEP
	echo "|    IP address    | Model  | Serial | Verion (build)  | Label            |"
	echo "+==================+========+========+=================+==================+"

	for IP in ${IP_LIST[@]}
	do
		# Print the device IP
		printf "| %16s " $IP

		# Is the device online (reachable) ?
		if is_online $IP ; then
			#Is it an IPS ?
			if probe_ips $IP; then
				# Print info line
				printf "| RN%04s | %04s | %04s (%08s) | %16s |\n" \
					"$(get_model $IP)" "$(get_serial $IP)" "$(get_version $IP)" "$(get_build $IP)" "$(get_label $IP)"
					# Print serparator
				echo $LINE_SEP
			elif [ ! -z $IP_LIST_FILE ]; then
				# If the IP are getted from the file, display the status
				printf "| %-52s |\n" "Not an IPS" 
				echo $LINE_SEP
			else
				# Erase the line
				printf "\r"
			fi
		elif [ ! -z $IP_LIST_FILE ]; then
			# If the IP are getted from the file, display the status
			printf "| %-52s |\n" "Offline" 
			echo $LINE_SEP
		else
			# Else, erase the line
			printf "\r"
		fi
	done


	exit 0
fi

