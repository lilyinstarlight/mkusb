#!/bin/sh -e
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
	cat >&2 <<EOF
$0 [distros] [device] [efi partition] [live partition]

  See mkusb(1) manual page for more info
EOF
	exit
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "error: script must be run as root"
	exit 1
fi

# whether to partition with fat or ext2
fat=1

# get system configuration
if [ -n "$MKUSB_GRUB" ]; then
	sysgrub="$MKUSB_GRUB"
elif which grub2-install >/dev/null 2>/dev/null; then
	sysgrub=grub2
else
	sysgrub=grub
fi

if [ -n "$MKUSB_GRUB_EFI" ]; then
	sysgrubefi="$MKUSB_GRUB_EFI"
else
	sysgrubefi="$sysgrub"-install
fi

if [ -n "$MKUSB_GRUB_PC" ]; then
	sysgrubpc="$MKUSB_GRUB_PC"
else
	sysgrubpc="$sysgrub"-install
fi

if [ -n "$MKUSB_MEMDISK" ]; then
	sysmemdisk="$MKUSB_MEMDISK"
elif [ -e /usr/lib/syslinux/bios/memdisk ]; then
	sysmemdisk="/usr/lib/syslinux/bios/memdisk"
else
	sysmemdisk="/usr/share/syslinux/memdisk"
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
	devs="$(find /dev/disk/by-path | grep -- '-usb-' | grep -v -- '-part[0-9]*$' || true)"

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
	# sector sizes
	secstart=2048
	secefi=1048576

	# partition device
	echo "partitioning..."
	dd if=/dev/zero of="$dev" count=$secstart >/dev/null 2>/dev/null
	sfdisk "$dev" >/dev/null <<EOF
label: dos
device: $dev
unit: sectors

${dev}1 : start=$secstart, size=$(expr "$(blockdev --getsz "$dev")" - $secstart - $secefi), type=b
${dev}2 : size=$secefi, type=ef
EOF
	blockdev --rereadpt "$dev"

	if [ -b "$dev"p1 ]; then
		livepart="$dev"p1
		efipart="$dev"p2
	else
		livepart="$dev"1
		efipart="$dev"2
	fi

	unset secstart
	unset secefi

	# format device
	echo "formatting..."
	if [ $fat -ne 0 ]; then
		mkfs.fat -F 32 -n "$label" "$livepart" >/dev/null
	else
		mkfs.ext2 -L "$label" "$livepart" >/dev/null
	fi
	mkfs.fat -F 32 -n ESP "$efipart" >/dev/null

	formatted=1
fi

# mount devie
echo "mounting..."
livemnt="$(mktemp -d)"
efimnt="$(mktemp -d)"
mount "$livepart" "$livemnt"
mount "$efipart" "$efimnt"

trap "(set +e; umount '$livemnt'; rmdir '$livemnt'; umount '$efimnt'; rmdir '$efimnt') >/dev/null 2>/dev/null" EXIT

unset efipart

# install grub
echo "installing grub..."
"$sysgrubefi" --target=x86_64-efi --boot-directory="$efimnt" --efi-directory="$efimnt" --removable >/dev/null
"$sysgrubpc" --target=i386-pc --boot-directory="$efimnt" "$dev" >/dev/null

unset dev

# copy config and distros
echo "copying distros..."

# create empty grub configuration
printf "" >"$livemnt"/grub.cfg

label() {
	label="$1"

	if [ -n "$formatted" ]; then
		umount "$livepart"
		if [ $fat -ne 0 ]; then
			fatlabel "$livepart" "$label" >/dev/null
		else
			e2label "$livepart" "$label" >/dev/null
		fi
		mount "$livepart" "$livemnt"
	fi
}

iso() {
	printf "	%s\n" "$1"
	cat >>"$livemnt"/grub.cfg <<EOF
menuentry '$1' {
	set filename=/$(basename "$2")
	set label=$label
	loopback iso \$filename
EOF

	IFS='#' read -r kernel64 kernel32 <<EOF
$(printf "%s" "$3" | sed -e 's/[[:space:]]*--[[:space:]]*/#/g')
EOF
	IFS='#' read -r initrd64 initrd32 <<EOF
$(printf "%s" "$4" | sed -e 's/[[:space:]]*--[[:space:]]*/#/g')
EOF
	IFS='#' read -r param64 param32 <<EOF
$(printf "%s" "$5" | sed -e 's/%\([^%]\+\)%/$\1/g' | sed -e 's/[[:space:]]*--[[:space:]]*/#/g')
EOF

	if [ -n "$kernel32" ]; then
		if [ -z "$initrd32" ]; then
			initrd32="$initrd64"
		fi

		if [ -z "$param32" ]; then
			param32="$param64"
		fi

		cat >>"$livemnt"/grub.cfg <<EOF
	if cpuid -l; then
		linux (iso)$kernel64 $param64
		initrd$(for initrd in $initrd64; do printf " (iso)%s" "$initrd"; done)
	else
		linux (iso)$kernel32 $param32
		initrd$(for initrd in $initrd32; do printf " (iso)%s" "$initrd"; done)
	fi
EOF
	else
		cat >>"$livemnt"/grub.cfg <<EOF
	linux (iso)$kernel64 $param64
	initrd$(for initrd in $initrd64; do printf " (iso)%s" "$initrd"; done)
EOF
	fi

	unset param64
	unset param32
	unset initrd64
	unset initrd32
	unset kernel64
	unset kernel32

	cat >>"$livemnt"/grub.cfg <<EOF
}

EOF

	iso="$livemnt/$(basename "$2")"

	{ [ ! -e "$iso" ] || [ -n "$(find -L "$2" -prune -newer "$iso" -exec echo . ';')" ]; } && cp "$2" "$iso"

	unset iso
}

freedos() {
	printf "	%s\n" "$1"
	cat >>"$livemnt"/grub.cfg <<EOF
menuentry '$1' {
	insmod progress

	set filename=/$(basename "$2")
	set label=$label
	linux16 /memdisk
	initrd16 /\$filename
}

EOF

	memdisk="$livemnt/memdisk"

	{ [ ! -e "$memdisk" ] || [ -n "$(find -L "$sysmemdisk" -prune -newer "$memdisk" -exec echo . ';')" ]; } && cp "$sysmemdisk" "$memdisk"

	img="$livemnt/$(basename "$2")"

	{ [ ! -e "$img" ] || [ -n "$(find -L "$2" -prune -newer "$img" -exec echo . ';')" ]; } && cp "$2" "$img"

	unset memdisk
	unset img
}

refind() {
	printf "	%s\n" "$1"

	refindmnt="$(mktemp -d)"
	mount -o ro "$2" "$refindmnt"

	cat >>"$livemnt"/grub.cfg <<EOF
if [ \${grub_platform} == "efi" ]; then
	menuentry '$1' {
		search --no-floppy --file --set=root /EFI/refind/bootx64.efi

		if cpuid -l; then
			chainloader /EFI/refind/bootx64.efi
		else
			chainloader /EFI/refind/bootia32.efi
		fi
	}
fi

EOF

	cp -r "$refindmnt"/EFI/boot "$efimnt"/EFI/refind
	cp -r "$refindmnt"/EFI/tools "$efimnt"/EFI/tools

	rm -rf "$livemnt"/refind
	cp -r "$refindmnt" "$livemnt"/refind
	rm -rf "$livemnt"/refind/EFI

	umount "$refindmnt"
	unset refindmnt
}

. "$(readlink -f $distros)"

# configure grub
echo "configuring grub..."
cat >"$efimnt"/"$sysgrub"/grub.cfg <<EOF
if loadfont /$sysgrub/fonts/unicode.pf2; then
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
