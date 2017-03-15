#!/bin/sh
if [ "$UID" -ne "0" ]; then
	echo "error: script must be run as root"
	exit 1
fi

# get distro configuration
distros="$1"
if [ -z "$distros" ]; then
	distros="./distros"
fi

# get device
dev="$2"
if [ -z "$dev" ]; then
	echo "getting device..."
	devs="$(find /dev/disk/by-path | grep -- '-usb-' | grep -v -- '-part[0-9]*$')"

	if [ -z "$devs" ]; then
		echo "error: no usb device found"
		exit 2
	fi

	devs="$(readlink -f $devs)"

	dialogdevs=""

	dialogmodel=""
	for dialogdev in $devs; do
		dialogmodel="$(lsblk -ndo model "$dialogdev")"
		dialogdevs="$dialogdevs $dialogdev '$dialogmodel' off"
	done
	unset dialogdev
	unset dialogmodel

	while [ -z "$dev" ]; do
		dev="$(eval "dialog --stdout --radiolist 'select usb device' 12 40 5 $dialogdevs")"
		if [ "$?" -ne "0" ]; then
			exit
		fi
	done

	unset dialogdevs

	unset devs
fi

# store label
label="LIVE"

# get partition
efipart="$3"
livepart="$4"
if [ -z "$efipart" ] || [ -z "$livepart" ]; then
	# partition device
	echo "partitioning..."
	fdisk "$dev" >/dev/null <<EOF
o
n



+$(expr $(blockdev --getsize64 "$dev") / 1024 - 524288)K
t
b
n




t

ef
w
EOF

	livepart="$dev"1
	efipart="$dev"2

	# format device
	echo "formatting..."
	mkfs.fat -F 32 -n "$label" "$livepart" >/dev/null
	mkfs.fat -F 32 -n ESP "$efipart" >/dev/null

	formatted=1
fi

# mount devie
echo "mounting..."
livemnt="$(mktemp -d)"
efimnt="$(mktemp -d)"
mount "$livepart" "$livemnt"
mount "$efipart" "$efimnt"

unset efipart

# install grub
echo "installing grub..."
grub-install --target=i386-pc --boot-directory="$efimnt" "$dev" >/dev/null
grub-install --target=x86_64-efi --boot-directory="$efimnt" --efi-directory="$efimnt" --removable >/dev/null

unset dev

# copy config and distros
echo "copying distros..."

# create empty grub configuration
echo -n "" >"$livemnt"/grub.cfg

label() {
	label="$1"

	if [ -n "$formatted" ]; then
		umount "$livepart"
		fatlabel "$livepart" "$label" >/dev/null
		mount "$livepart" "$livemnt"
	fi
}

iso() {
	echo -e "\t$1"
	cat >>"$livemnt"/grub.cfg <<EOF
menuentry '$1' {
	set filename=/$(basename "$2")
	set label=$label
	loopback iso \$filename
EOF

	params="$(sed -e "s/%\([^%]\+\)%/\$\1/g" <<<$5)"
	read kernel64 kernel32 <<<$3

	if [ -n "$kernel32" ]; then
		cat >>"$livemnt"/grub.cfg <<EOF
	if cpuid -l; then
		linux (iso)$kernel64 $params
	else
		linux (iso)$kernel32 $params
	fi
EOF
	else
		cat >>"$livemnt"/grub.cfg <<EOF
	linux (iso)$kernel64 $params
EOF
	fi

	unset params
	unset kernel64
	unset kernel32

	cat >>"$livemnt"/grub.cfg <<EOF
	initrd$(for initrd in $4; do echo -n " (iso)$initrd"; done)
}

EOF

	cp "$2" "$livemnt"/
}

source "$(readlink -f $distros)"

# configure grub
echo "configuring grub..."
cat >"$efimnt"/grub/grub.cfg <<EOF
if loadfont /grub/fonts/unicode.pf2; then
	set gfxmode=auto

	if [ \${grub_platform} == "efi" ]; then
		insmod efi_gop
		insmod efi_uga
	else
		insmod all_video
	fi

	insmod gfxterm
	terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

set gfxpayload=keep

search --no-floppy --label --set=root $label

source /grub.cfg
EOF

unset livepart
unset label
unset distros

# sync
echo "syncing..."
sync

# unmount
echo "unmounting..."
umount "$efimnt"
umount "$livemnt"
rmdir "$efimnt"
rmdir "$livemnt"

unset efimnt
unset livemnt

echo "done"
