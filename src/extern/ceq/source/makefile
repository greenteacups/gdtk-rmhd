CC = gcc
CFLAGS := -I. -fPIC -Wall -std=c99 -O3
INSTALL_DIR ?= $(HOME)/ceq

all: thermo.o linalg.o common.o pt.o rhou.o ps.o rhot.o ceq.o
	$(CC) $(CFLAGS) -shared thermo.o linalg.o common.o pt.o rhou.o ps.o rhot.o ceq.o -lm -o libceq.so
	ar r libceq.a thermo.o linalg.o common.o pt.o rhou.o ps.o rhot.o ceq.o
	ranlib libceq.a

thermo.o: thermo.c thermo.h
	$(CC) $(CFLAGS) -c thermo.c

linalg.o: linalg.c linalg.h
	$(CC) $(CFLAGS) -c linalg.c

common.o: common.c common.h
	$(CC) $(CFLAGS) -c common.c

pt.o: pt.c thermo.h linalg.h common.h pt.h
	$(CC) $(CFLAGS) -c pt.c

rhou.o: rhou.c thermo.h linalg.h common.h rhou.h
	$(CC) $(CFLAGS) -c rhou.c

ps.o: ps.c thermo.h linalg.h common.h ps.h
	$(CC) $(CFLAGS) -c ps.c

rhot.o: rhot.c thermo.h linalg.h common.h rhot.h
	$(CC) $(CFLAGS) -c rhot.c

ceq.o: ceq.c thermo.h pt.h rhou.h ps.h rhot.h ceq.h
	$(CC) $(CFLAGS) -c ceq.c

install: 
	mkdir -p $(INSTALL_DIR)
	cp libceq.so $(INSTALL_DIR)
	sed -e "s+DBPATH='../thermo.inp'+DBPATH='$(INSTALL_DIR)/thermo.inp'+" \
        -e "s+LIBPATH='./libceq.so'+LIBPATH='$(INSTALL_DIR)/libceq.so'+" \
	    -e "s+HEADERFILE='./ceq.h'+HEADERFILE='$(INSTALL_DIR)/ceq.h'+" \
        pyeq.py > $(INSTALL_DIR)/pyeq.py
	cp 'clib.py' $(INSTALL_DIR)
	cp '../thermo.inp' $(INSTALL_DIR)
	cp 'ceq.h' $(INSTALL_DIR)
	cp -r ../tests $(INSTALL_DIR)/

moduletests: thermo.c thermo.h thermo.o linalg.c linalg.h linalg.o
	$(CC) thermo.c -D TEST -lm -o ../tests/testthermo
	$(CC) linalg.c -D TEST -lm -o ../tests/testlinalg

clean: 
	rm -rf *.o *.obj
	rm -rf libceq.so libceq.a
