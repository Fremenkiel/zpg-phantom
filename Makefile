.PHONY: test-reflink

test-reflink:
	zig test src/reflink.zig
	zig test src/reflink.zig -target aarch64-linux-musl -femit-bin=test-linux --test-no-exec
	docker run --rm -it --privileged -v "$$PWD:/work" alpine:latest sh -c ' \
		apk add --no-cache btrfs-progs e2fsprogs-extra && \
		dd if=/dev/zero of=/tmp/btrfs.img bs=1M count=200 && \
		mkfs.btrfs -q /tmp/btrfs.img && \
		mkdir -p /mnt/cow_test && \
		mount -o loop /tmp/btrfs.img /mnt/cow_test && \
		cd /mnt/cow_test && \
		/work/test-linux \
		'
	rm test-linux
