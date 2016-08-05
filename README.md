mkusb
=====

mkusb is a shell script to create ISO multiboot USB flash drives that support both legacy and EFI boot.


Requirements
============

* grub2
* dosfstools
* dialog (optional; required if not specifying device on command line)
* sane environment (util-linux, coreutils, etc.)


Usage
=====

Edit a distros file and an optional label definition and multiple iso definitions in the following format:

    label <filesystem label>
    iso <iso name> <kernel> <initrd> <boot flags>
    iso <iso name> <kernel> <initrd> <boot flags>
    ...

The boot flags are parsed for '%variable%' expressions and fills them out to GRUB variables. Currently only '%filename%' and '%label%' are supported. Arguments with a space or characters parsed by the shell must be quoted. Most of these arguments can be found by mounting the ISO file and checking the boot parameters in it. Because the distros file is just a shell script, more advanced features can be added like conditionally adding ISO files based on the environment. An example distros file is provided in this repository.

Run the mkusb script in your shell:

    $ sudo ./mkusb.sh [distros] [device] [efi partition] [live partition]

If the distros file is omitted, the script will default to a file called 'distros' in the current working directory. If device is omitted, you will be prompted to select from available removable devices. If the partitions are omitted, the device will be formatted to have one EFI system partition and one live images partition.
