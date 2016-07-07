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

# get partition
part="$3"
if [ -z "$part" ]; then
	# partition device
	echo "partitioning..."
	fdisk "$dev" >/dev/null <<EOF
o
n




t
ef
w
EOF

	part="$dev"1

	# format device
	echo "formatting..."
	mkfs.fat "$part" >/dev/null
fi

# mount devie
echo "mounting..."
mnt="$(mktemp -d)"
mount "$part" "$mnt"

unset part

# install grub
echo "installing grub..."
grub2-install --target=i386-pc --boot-directory="$mnt" "$dev" >/dev/null
grub2-install --target=x86_64-efi --boot-directory="$mnt" --efi-directory="$mnt" --removable >/dev/null

unset dev

# configure and copy distros
echo "configuring grub and copying distros..."
cat >"$mnt"/grub/grub.cfg <<EOF
if loadfont /grub/fonts/unicode.pf2; then
	set gfxmode=auto
	insmod efi_gop
	insmod efi_uga
	insmod gfxterm
	terminal_output gfxterm
fi

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

set gfxpayload=keep
EOF

iso() {
	echo -e "\t$1"
	cat >>"$mnt"/grub/grub.cfg <<EOF

menuentry '$1' {
	set filename=/$(basename "$2")
	loopback iso \$filename
	linux (iso)$3 $5 $6=\$filename
	initrd $(for initrd in $4; do echo "(iso)$initrd"; done)
}
EOF

	cp "$2" "$mnt"/
}

source "$distros"

unset distros

# sync
echo "syncing..."
sync

# unmount
echo "unmounting..."
umount "$mnt"
rmdir "$mnt"

unset mnt

echo "done"
