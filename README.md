mkusb
=====

mkusb is a shell script to create ISO multiboot USB flash drives that support both legacy and EFI boot.


Usage
=====

Edit a distros file and add ISOs separated by newlines in the following format:

    iso <iso name> <kernel> <initrd> <boot flags> <isoscan flag>

Arguments with a space or characters parsed by the shell must be quoted. Most of these arguments can be found by mounting the ISO file and checking the boot parameters in it. Because the distros file is just a shell script, more advanced features can be added like conditionally adding ISO files based on the environment. An example distros file is provided in this repository.

Run the mkusb script in your shell:

    $ sudo ./mkusb.sh [distros]

If the distros file is omitted, the script will default to a file called 'distros' in the current working directory.
