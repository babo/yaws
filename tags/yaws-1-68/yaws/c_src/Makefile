include ../include.mk


# don't c-compile anything on win32 (yet)
# I don't know how to make a linked in driver using gcc, or any
# other compiler there, and have no intentions of finding out

ifdef WIN32
	PRIV_FILES=../priv/.foo
else
# don't make pam if configured out with --disable-pam
	PRIV_FILES= ../priv/setuid_drv.$(DLL)  $(EPAM)
endif


CFLAGS += -I"${ERLDIR}/usr/include"

# and for MacOs + possibly others ...
CFLAGS += -I/usr/include/pam/ $(EXTRAINCLUDE)

#
# Targets
#

all: $(PRIV_FILES) 

clean:
	-rm -f $(PRIV_FILES) setuid_drv.$(OBJ) 

install:	$(PRIV_FILES)
	$(INSTALL) -d $(DESTDIR)$(PREFIX)/lib/yaws/priv
	$(INSTALL) $(PRIV_FILES) $(DESTDIR)$(PREFIX)/lib/yaws/priv
ifndef WIN32
	if [ `id -u` = "0" -a -d $(DESTDIR)$(PREFIX)/lib/yaws/priv/epam ]; then \
		chown root $(DESTDIR)$(PREFIX)/lib/yaws/priv/epam; \
		chmod a+s $(DESTDIR)$(PREFIX)/lib/yaws/priv/epam; \
	fi
endif


../priv/setuid_drv.$(DLL): setuid_drv.$(OBJ)
	$(LD_SHARED) $(OUT) $@  setuid_drv.$(OBJ) $(DLL_LIBS)
setuid_drv.$(OBJ):	setuid_drv.c
	$(CC) -c $(FPIC) $(CFLAGS) -DDYNAMIC_DRIVER setuid_drv.c

../priv/.foo:
	touch ../priv/.foo	

epam.o:	epam.c
	$(CC) -c $(CFLAGS) epam.c
../priv/epam: epam.o
	$(CC) -o $@ epam.o -lpam
