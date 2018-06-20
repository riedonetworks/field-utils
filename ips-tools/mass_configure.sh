#!/bin/bash

# mass_configure.sh
#
# This script has can do mass configuration of IPS devices. See help text for more information
#
# (c) 2018, Riedo Networks Ltd
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
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

########################################################
# Change log:
#  - 20.06.2018: Initial release
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


function do_ips_command_check()
{
	LOG=$(do_ips_command "$1" "$2")
	echo $LOG | grep "Command failed" > /dev/null
	if [ $? -eq 0 ]
	then
		echo "Warning: Command \"$2\" Failed !"
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



function usage() {
	echo "Usage: $ME [-t TIMEOUT] [-c command] [ -c command] [-r|--range START_IP END_IP] [-f|--file IP_LIST_FILE] [-t TIMEOUT] " | fold -s
	echo ""
	echo " Execute command on IPS in mass."
	echo ""
	echo "Execute command on batch of IPS devices. IPS devices are accessed trough TCP/IP/Ethernet. IPS devices are referenced by they IP addresses. " | fold -s
	echo ""
	echo "The list of devices to address is ether given by a file ('-f' option) or by a range ('-r' option). The file ('-f' option) must contains one IP address per line. If the range is given ('-r' option), the first address and the last address of the range must be provided. They can be blank address within the range."| fold -s
	echo "The commands to exectue on the devices are given using the '-c' options. If the command is more than a world, then the command must be surrounded with quote marks (\"). More that one command can be given. In that case, command are executed in order." | fold -s
	echo ""
	echo "Options:"
	echo "  -c, --command     Give the command to execute. Can be present"
	echo "                    more than once. Executed in order"
	echo "  -r, --range		  Specify the IP address range"
	echo "  -f, --file        Specify a file containing one IP addres per line"
	echo "  -t, --timeout     Specify connection timeout (default=$TIMEOUT seconds)"
	echo "  -h, --help        Display this help and exit"
}



### MAIN ######################################################################

### Parse argument
ME=$0
COMMANDS=()
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
		-c|--command)
			shift
			COMMANDS+=("$1")
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

echo "IP_LIST=${IP_LIST[@]}"



for i in ${!COMMANDS[@]}
do
	echo "COMMANDS[$i] = ${COMMANDS[i]}"

done

for i in ${!POS_ARGS[@]}
do
	echo "POS_ARGS[$i] = ${POS_ARGS[i]}"

done

# Check that no positional arugment is given
if [ ${#POS_ARGS[@]} -gt 0 ]
then
	echo "ERROR: $ME does not use positional argument! (Did you forget to surround command with '\"' ?)" | fold -s
	exit 1
fi

for IP in ${IP_LIST[@]}
do
	if is_online $IP
	then
		echo -n "Configuring $IP..."

		for i in ${!COMMANDS[@]}
		do
			CMD="${COMMANDS[i]}"
			do_ips_command_check "$IP" "$CMD"
		done

		echo DONE

	else
		echo "$IP is off-line  (does not response)."
	fi
done
