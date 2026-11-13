## Process this file with automake to produce Makefile.in

AUTOMAKE_OPTIONS = foreign

check_PROGRAMS = test test_codebook bench_decode

check: $(check_PROGRAMS)
	./test$(EXEEXT)
	./test_codebook$(EXEEXT)
	./bench_decode$(EXEEXT)

AM_CPPFLAGS = -I$(top_srcdir)/include @OGG_CFLAGS@

test_SOURCES = util.c util.h write_read.c write_read.h test.c
test_LDADD = ../lib/libvorbisenc.la ../lib/libvorbis.la @OGG_LIBS@ @VORBIS_LIBS@

test_codebook_SOURCES = test_codebook.c
test_codebook_LDADD = ../lib/libvorbis.la @OGG_LIBS@ @VORBIS_LIBS@

bench_decode_SOURCES = bench_decode.c
bench_decode_LDADD = ../lib/libvorbisfile.la ../lib/libvorbisenc.la ../lib/libvorbis.la @OGG_LIBS@ @VORBIS_LIBS@

EXTRA_DIST = CMakeLists.txt

debug:
	$(MAKE) check CFLAGS="@DEBUG@"

profile:
	$(MAKE) check CFLAGS="@PROFILE@"
