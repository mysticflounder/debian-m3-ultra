KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m := arm64-el1-probe.o

.PHONY: all clean

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
