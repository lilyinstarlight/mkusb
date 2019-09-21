#!/bin/sh -e
if [ "`id -u`" -ne 0 ]; then
	echo "error: script must be run as root"
	exit 1
fi

# whether to partition with fat or ext2
fat=1

if [ $fat -eq 0 ] && [ "`uname`" == "Darwin" ]; then
	echo "error: only fat is supported on macOS"
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
	if [ "`uname`" == "Darwin" ]; then
		devs="`for dev in \`diskutil list | grep '^/' | cut -d' ' -f1\`; do diskutil info $dev | grep 'Removable$' >/dev/null && echo $dev; done`"
	else
		devs="`find /dev/disk/by-path | grep -- '-usb-' | grep -v -- '-part[0-9]*$' || true`"
	fi

	if [ -z "$devs" ]; then
		echo "error: no usb device found"
		exit 2
	fi

	if [ "`uname`" == "Linux" ]; then
		devs="`readlink -f $devs`"
	fi

	dialogdevs=""

	dialogmodel=""
	for dialogdev in $devs; do
		if [ "`uname`" == "Darwin" ]; then
			dialogmodel="`diskutil info $dialogdev | grep 'Device / Media Name:' | sed -e 's#   Device / Media Name:      ##'`"
		else
			dialogmodel="`lsblk -ndo model "$dialogdev"`"
		fi
		dialogdevs="$dialogdevs $dialogdev '$dialogmodel' off"
	done
	unset dialogdev
	unset dialogmodel

	while [ -z "$dev" ]; do
		dev="`eval "dialog --stdout --radiolist 'select usb device' 12 40 5 $dialogdevs"`"
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
	if [ "`uname`" == "Darwin" ]; then
		diskutil unmountDisk "$dev" &>/dev/null
	fi
	dd if=/dev/zero of="$dev" count=$secstart &>/dev/null
	if [ "`uname`" == "Darwin" ]; then
		total=`diskutil info "$dev" | grep "Disk Size" | cut -d\( -f2 | cut -d' ' -f1`
		size=`expr $total - $secstart '*' 512 - $secefi '*' 512`

		diskutil partitionDisk "$dev" 2 MBR FAT32 %noformat% $size EFI %noformat% R >/dev/null

		unset size
		unset total

		livepart="$dev"s1
		efipart="$dev"s2
	else
		total=`blockdev --getsz "$dev"`
		size=`expr $total - $secstart - $secefi`

		sfdisk "$dev" >/dev/null <<EOF
label: dos
device: $dev
unit: sectors

${dev}1 : start=$secstart, size=$size, type=b
${dev}2 : size=$secefi, type=ef
EOF

		unset size
		unset total

		blockdev --rereadpt "$dev"

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
livemnt="`mktemp -d`"
efimnt="`mktemp -d`"
if [ "`uname`" == "Darwin" ]; then
	mount -t msdos "$livepart" "$livemnt"
	mount -t msdos "$efipart" "$efimnt"
else
	mount "$livepart" "$livemnt"
	mount "$efipart" "$efimnt"
fi

if [ "`uname`" == "Darwin" ]; then
	trap "(set +e; diskutil unmount '$livemnt'; rmdir '$livemnt'; diskutil unmount '$efimnt'; rmdir '$efimnt') &>/dev/null" EXIT
else
	trap "(set +e; umount '$livemnt'; rmdir '$livemnt'; umount '$efimnt'; rmdir '$efimnt') &>/dev/null" EXIT
fi

unset efipart

# install grub
echo "installing grub..."
if [ "`uname`" == "Linux" ]; then
	grub-install --target=i386-pc --boot-directory="$efimnt" "$dev" >/dev/null
fi
grub-install --target=x86_64-efi --boot-directory="$efimnt" --efi-directory="$efimnt" --removable >/dev/null

unset dev

# copy config and distros
echo "copying distros..."

# create empty grub configuration
echo -n "" >"$livemnt"/grub.cfg

label() {
	label="$1"

	if [ -n "$formatted" ]; then
		if [ "`uname`" == "Darwin" ]; then
			diskutil unmount "$livepart"
		else
			umount "$livepart"
		fi
		if [ $fat -ne 0 ]; then
			fatlabel "$livepart" "$label" >/dev/null
		else
			e2label "$livepart" "$label" >/dev/null
		fi
		if [ "`uname`" == "Darwin" ]; then
			mount -t msdos "$livepart" "$livemnt"
		else
			mount "$livepart" "$livemnt"
		fi
	fi
}

iso() {
	echo -e "\t$1"
	cat >>"$livemnt"/grub.cfg <<EOF
menuentry '$1' {
	set filename=/`basename "$2"`
	set label=$label
	loopback iso \$filename
EOF

	IFS='#' read kernel64 kernel32 <<EOF
`echo "$3" | sed -e 's/[[:space:]]*--[[:space:]]*/#/g'`
EOF
	IFS='#' read initrd64 initrd32 <<EOF
`echo "$4" | sed -e 's/[[:space:]]*--[[:space:]]*/#/g'`
EOF
	IFS='#' read param64 param32 <<EOF
`echo "$5" | sed -e 's/%\([^%]\+\)%/$\1/g' | sed -e 's/[[:space:]]*--[[:space:]]*/#/g'`
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
		initrd`for initrd in $initrd64; do echo -n " (iso)$initrd"; done`
	else
		linux (iso)$kernel32 $param32
		initrd`for initrd in $initrd32; do echo -n " (iso)$initrd"; done`
	fi
EOF
	else
		cat >>"$livemnt"/grub.cfg <<EOF
	linux (iso)$kernel64 $param64
	initrd`for initrd in $initrd64; do echo -n " (iso)$initrd"; done`
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

	iso="$livemnt/`basename "$2"`"

	([ ! -e "$iso" ] || [ "$iso" -ot "$2" ]) && cp "$2" "$iso"

	unset iso
}

refind() {
	echo -e "\t$1"

	refindmnt="`mktemp -d`"
	if [ "`uname`" == "Darwin" ]; then
		mount -t cd9660 -o ro "$2" "$refindmnt"
	else
		mount -o ro "$2" "$refindmnt"
	fi

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

	if [ "`uname`" == "Darwin" ]; then
		diskutil unmount "$refindmnt"
	else
		umount "$refindmnt"
	fi
	unset refindmnt
}

if [ "`uname`" == "Darwin" ]; then
	source "$distros"
else
	source "`readlink -f "$distros"`"
fi

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
if [ "`uname`" == "Darwin" ]; then
	diskutil unmount "$efimnt"
	diskutil unmount "$livemnt"
else
	umount "$efimnt"
	umount "$livemnt"
fi
rmdir "$efimnt"
rmdir "$livemnt"

unset efimnt
unset livemnt

echo "done"
