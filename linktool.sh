#! /bin/sh
#
# Copyright (c) 2013 Petar Bogdanovic <petar@smokva.net>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

linkwatch_init ()
{
	local fifo=$1
	LINKWATCH_WASTE="$LINKWATCH_WASTE'$fifo' "

	mkfifo -m 0600 "$fifo" &&
		trap linkwatch_fini EXIT
	return $?
}

linkwatch_fini ()
{
	eval rm $LINKWATCH_WASTE 2>/dev/null
	eval ${LINKWATCH_SKIPTERM:+#} kill 0
}

linkwatch_test_int ()
{
	local int=$1

	ifconfig "$int" >/dev/null
	return $?
}

linkwatch_cmd_watch ()
{
	local key=$1

	cat <<-EOF
	n.add $key
	n.watch
	EOF
}

linkwatch_cmd_get ()
{
	local key=$1

	cat <<-EOF
	get $key
	d.show
	EOF
}

linkwatch_enq ()
{
	LINKWATCH_Q="${LINKWATCH_Q}$1 "
}

linkwatch_deq ()
{
	LINKWATCH_Q=${LINKWATCH_Q#* }
}

linkwatch_parse ()
{
	local ints=$*
	local keystr=State:/Network/Interface/\$int/Link
	local int= key= line=

	for int in $ints; do
		eval key=$keystr
		linkwatch_cmd_get $key >&3
		linkwatch_cmd_watch $key >&3
		linkwatch_enq $int
	done
	while read line; do
		for int in $LINKWATCH_Q; do
			case "$line" in
			Active?:?FALSE)
				echo $int:off
				linkwatch_deq
				continue 2
				;;
			Active?:?TRUE)
				echo $int:on
				linkwatch_deq
				continue 2
				;;
			esac 2>/dev/null
		done
		for int in $ints; do
			eval key=$keystr
			case "$line" in
			*$key)
				linkwatch_cmd_get $key >&3
				linkwatch_enq $int
				break
				;;
			esac
		done
	done
}

linkwatch ()
{
	local ints=$*
	local fifo=/tmp/.linkwatch-$$
	local int=

	for int in $ints; do
		linkwatch_test_int "$int" || return $?
	done
	linkwatch_init "$fifo" || return $?
	scutil <$fifo | linkwatch_parse $ints 3>$fifo &
	wait
}

linkmap_init ()
{
	local lock=$1
	LINKMAP_WASTE="$LINKMAP_WASTE'$lock' "

	for i in 1 2 3; do
		ln -s "$$" "$lock" && break
		kill "$(readlink "$lock")"
		sleep $i
		! :
	done || return 1
	trap linkmap_fini EXIT &&
		export LINKWATCH_SKIPTERM=y
	return $?
}

linkmap_fini ()
{
	eval rm $LINKMAP_WASTE 2>/dev/null
	eval ${LINKMAP_SKIPTERM:+#} kill 0
}

linkmap_getkey ()
{
	local vm=$1
	local key=$2

	VBoxManage showvminfo "$vm" --machinereadable |
		awk '!val {
			n = split($0, A, /'"$key"'="|"/)
			if (n == 3 && !A[1] && !A[3]) {
				val = A[2]
				print val
			}
		}'
}

linkmap_test_vbox ()
{
	local vm=$1
	local re_comm="VirtualBoxVM(-amd|-x86)?"
	local re_args="--startvm $vm"

	ps -xo ucomm=,args= |
		egrep -qs "^$re_comm .* $re_args"
	return $?
}

linkmap_match ()
{
	local var=$1
	local pat=$2

	case "$var" in
	$pat) return 0 ;;
	esac
	return 1
}

linkmap_parse ()
{
	local vm=$1
	shift 1
	local maps=$*
	local host=$(hostname -s)
	local vmname=$(linkmap_getkey "$vm" name)
	local intstat= int= stat= map= ints=

	while read intstat; do
		linkmap_test_vbox "$vm" || kill 0
		int=${intstat%:*}
		stat=${intstat#*:}
		for map in $maps; do
			linkmap_match "$map" "$int:*" && break
		done
		ints=${map#*:}
		IFS=$IFS:
		for i in $ints; do
			linkmap_match "$i" "[1-8]" || continue
			echo "Mapping link status ($stat):" \
				"$host/$int -> $vmname/nic$i"
			for j in 3 4 5 6 7 8 9 10 11 12; do
				VBoxManage controlvm "$vm" \
					setlinkstate"$i" $stat && break
				sleep $j
			done
		done
		IFS=${IFS%:}
	done
}

linkmap ()
{
	local vm=$(linkmap_getkey "$1" UUID)
	shift 1
	local maps=$*
	: ${maps:?no maps provided}
	local lockstr=/tmp/.linkmap-$vm
	local map= int= ints= lock=

	linkmap_test_vbox "$vm" || return $?
	for map in $maps; do
		int=${map%%:*}
		ints="$ints$int "
		lock="$lockstr-$int"
		linkmap_init "$lock" || return $?
	done
	linkwatch "$ints" | linkmap_parse "$vm" "$maps" &
	wait
}

linkmapper_init ()
{
	trap "kill 0" EXIT &&
		export LINKMAP_SKIPTERM=y
}

linkmapper_maps ()
{
	local vm=$1

	VBoxManage showvminfo "$vm" --machinereadable |
		awk -v ints="$(ifconfig -l)" '
		BEGIN {
			n = split(ints, A, / /)
			for (i=1; i<=n; i++) {
				INTS[A[i]] = i
			}
		}
		{
			n = split($0, A, /bridgeadapter|="|: /)
			if (n == 4 && A[2] ~ /^[1-8]$/ && INTS[A[3]]) {
				MAPS[A[3]] = MAPS[A[3]] ":" A[2]
			}
		}
		END {
			for (i in MAPS) {
				print i MAPS[i]
			}
		}'
}

linkmapper ()
{
	local vm=$1
	: ${vm:?no name/uuid provided}

	linkmapper_init || return $?
	linkmap "$vm" $(linkmapper_maps "$vm") &
	wait
}

linkwrapper ()
{
	local arg= next= vm=

	for arg in "$@"; do
		case "$next" in
		y) vm=$arg; break ;;
		esac
		case "$arg" in
		--startvm) next=y ;;
		esac
	done

	linkmapper "$vm"
}

linkseesaw_init ()
{
	local lock=$1
	LINKSEESAW_WASTE="$LINKSEESAW_WASTE'$lock' "

	ln -s "$$" "$lock" &&
		trap linkseesaw_fini EXIT &&
			export LINKWATCH_SKIPTERM=y
	return $?
}

linkseesaw_fini ()
{
	eval rm $LINKSEESAW_WASTE 2>/dev/null
	kill 0
}

linkseesaw_power ()
{
	local int=$1
	local stat=$2

	networksetup -setairportpower "$int" "$stat"
	return $?
}

linkseesaw_parse ()
{
	local master=$1
	local slave=$2
	local intstat=

	while read intstat; do
		case "$intstat" in
		$master:on)
			echo "master ($master) is on," \
				"turning slave ($slave) off"
			linkseesaw_power "$slave" off || kill 0 ;;
		$master:off)
			echo "master ($master) is off," \
				"turning slave ($slave) on"
			linkseesaw_power "$slave" on || kill 0 ;;
		esac
	done
}

linkseesaw ()
{
	local master=$1
	local slave=$2
	: ${master:?no interface provided}
	: ${slave:?no interface provided}
	local lock=/tmp/.linkseesaw-$master-$slave

	linkseesaw_init "$lock" || return $?
	linkwatch "$master" "$slave" | linkseesaw_parse "$master" "$slave" &
	wait
}

linksetup_rc ()
{
	local cmd_arch=$1

	cat <<-EOF
	#! /bin/sh
	screen -d -m sh -c "sleep 3; '$0' wrapper \$* 2>&1 | logger -t '${0##*/}'"
	exec '$cmd_arch' "\$@"
	EOF
}

linksetup ()
{
	# $2 -> VirtualBoxVM for now..
	local cmd=$1/Contents/Resources/VirtualBoxVM.app/Contents/MacOS/VirtualBoxVM
	local arch=x86

	case "$(uname -m)" in x86_64)
		arch=amd64 ;;
	esac
	cmp "$cmd" "$cmd-$arch" || return 1
	rm "$cmd" && linksetup_rc "$cmd-$arch" >"$cmd" && chmod +x "$cmd"
}

case "$1" in
watch|map|mapper|wrapper|seesaw|setup)
	command=$1
	shift 1
	link$command "$@"
	;;
*)
	echo "usage:
	${0##*/} watch host-if [host-if..]
	${0##*/} map guest host-if:guest-if[:guest-if..] [host-if:guest-if[:guest-if..]..]
	${0##*/} mapper guest
	${0##*/} wrapper --startvm guest
	${0##*/} seesaw master-host-if slave-host-if
	${0##*/} setup vbox-dir vbox-cmd

	guest      : name or UUID of any VM
	host-if    : host interface (see ifconfig)
	guest-if   : guest interface (integer, 1-8)
	vbox-dir   : path to VirtualBox.app directory
	vbox-cmd   : name of VirtualBox command" >&2
	exit 1
	;;
esac
