# Copyright (C) 2009 One Laptop per Child
# Licensed under the terms of the GNU GPL v2 or later; see COPYING for details.

. $OOB__shlib
versioned_fs=$(read_config base versioned_fs)
buildnr=$(read_buildnr)
BLOCK_SIZE=512
NUM_HEADS=16
NUM_SECTORS_PER_TRACK=62

# FIXME trap signals and cleanup
# FIXME check that traps due to errors are caught
BOOT=$intermediatesdir/mnt-boot
ROOT=$intermediatesdir/mnt-root

umount $BOOT &>/dev/null || :
umount $ROOT &>/dev/null || :
mkdir -p $BOOT
mkdir -p $ROOT


make_image()
{
	local vals=$1
	local disk_size=${vals%,*}
	local ext=
	expr index "$vals" ',' &>/dev/null && ext=${vals#*,}
	echo "Making image of size $disk_size"

	echo "Create disk and partitions..."

	local num_blocks=$(($disk_size / $BLOCK_SIZE))
	local num_cylinders=$(($num_blocks / $NUM_HEADS / $NUM_SECTORS_PER_TRACK))
	local image_size=$(($num_cylinders * $NUM_HEADS * $NUM_SECTORS_PER_TRACK * $BLOCK_SIZE))

	[ -z "$ext" ] && ext="zd"
	local img=$intermediatesdir/$(image_name).$ext.disk.img

	dd if=/dev/zero of=$img bs=$BLOCK_SIZE count=0 seek=$(($image_size / $BLOCK_SIZE))

	/sbin/sfdisk -S 32 -H 32 --force -uS $img <<EOF
8192,131072,83,*
139264,,,
EOF

	disk_loop=$(losetup --show --find --partscan $img)
	boot_loop="${disk_loop}p1"
	root_loop="${disk_loop}p2"

	echo "Create filesystems..."
	mke2fs -O dir_index,^resize_inode -L Boot -F $boot_loop
	mount $boot_loop $BOOT

	mkfs.ext4 -O dir_index,^huge_file -E resize=8G -m1 -L OLPCRoot $root_loop
	tune2fs -o journal_data_ordered $root_loop
	mount $root_loop $ROOT

	echo "Copy in root filesystem..."
	cp -a $fsmount/* $ROOT

	echo "Setup boot partition..."

	# runin testing needs this directory (#9840)
	# this needs to be done during build so that OFW can put files here
	# (e.g. updated tests) before the OS has ever booted
	mkdir -p $BOOT/runin

	# we put /security here as it's used by OFW, and should persist between
	# updates
	mkdir -p $BOOT/security

	# this is where Fedora's statetab tmpfs mount system puts its data.
	# the directory has to be created in advance
	mkdir -p $BOOT/security/state

	if [ "$versioned_fs" = "1" ]; then
		local tgt=$BOOT/boot-versions/$buildnr
		mkdir -p $tgt
		ln -s boot-versions/$buildnr $BOOT/boot
		ln -s boot/alt $BOOT/boot-alt
		cp -ar $ROOT/versions/pristine/$buildnr/boot/* $tgt
	else
		cp -ar $ROOT/boot/* $BOOT
		ln -s . $BOOT/boot
	fi

	umount $ROOT
	umount $BOOT
	losetup -d $disk_loop || :

	# FIXME: any value to running e2fsck now? maybe with -D ?
}


oIFS=$IFS
IFS=$'\n'
for line in $(env); do
	[[ "${line:0:24}" == "CFG_sd_card_image__size_" ]] || continue
	val=${line#*=}
	make_image $val
done
IFS=$oIFS

