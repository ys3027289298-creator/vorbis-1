#!/usr/bin/env bash
#
# verify-output-identity.sh - prove the leak fix does not change library
# output, sample for sample.
#
# It builds two non-instrumented libraries:
#   * reference : pristine HEAD sources (before the fix), via a git worktree
#   * candidate : the current working tree (with the fix)
# then encodes the same small generated material across the exact same
# parameter matrix the test suite uses (1..8 channels x 11 quality steps x
# 6 sample rates = 528 cases) and asserts, for every case, that:
#   1. the encoded Ogg/Vorbis byte stream is byte-identical, and
#   2. the decoded PCM samples are byte-identical.
#
# Usage:  scripts/verify-output-identity.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=toolchain.sh
source "$HERE/toolchain.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REF_SRC="$WORK/ref-src"
REF_BUILD="$WORK/ref-build"
CAND_BUILD="$WORK/cand-build"

section() { printf '\n==== %s ====\n' "$*"; }

# Tiny self-contained encoder: emits an Ogg/Vorbis stream of a generated
# windowed sine to stdout. Mirrors test/write_read.c but needs no temp files.
cat >"$WORK/enc_dump.c" <<'EOF'
#include <vorbis/codec.h>
#include <vorbis/vorbisenc.h>
#include <ogg/ogg.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
int main(int argc,char**argv){
  int ch=atoi(argv[1]); long rate=atol(argv[2]); float q=atof(argv[3]);
  int len=argc>4?atoi(argv[4]):2048;
  float *data=malloc((size_t)len*sizeof(float));
  for(int k=0;k<len/2;k++)
    data[k]=sin(2.0*k*M_PI/32.0+0.4f)*0.95f*
            (0.5f-0.5f*cos(2.0f*M_PI*k/(len/2-1)));
  for(int k=len/2;k<len;k++) data[k]=0;
  vorbis_info vi; vorbis_comment vc; vorbis_dsp_state vd; vorbis_block vb;
  ogg_stream_state os; ogg_page og; ogg_packet op;
  vorbis_info_init(&vi);
  if(vorbis_encode_init_vbr(&vi,ch,rate,q)){fprintf(stderr,"init fail\n");return 2;}
  vorbis_comment_init(&vc); vorbis_comment_add_tag(&vc,"ENCODER","dump");
  vorbis_analysis_init(&vd,&vi); vorbis_block_init(&vd,&vb);
  ogg_stream_init(&os,12345678);
  ogg_packet h,hc,hcode;
  vorbis_analysis_headerout(&vd,&vc,&h,&hc,&hcode);
  ogg_stream_packetin(&os,&h); ogg_stream_packetin(&os,&hc);
  ogg_stream_packetin(&os,&hcode);
  int eos=0;
  while(1){int r=ogg_stream_flush(&os,&og); if(!r)break;
    fwrite(og.header,1,og.header_len,stdout);
    fwrite(og.body,1,og.body_len,stdout);}
  float **buf=vorbis_analysis_buffer(&vd,len);
  for(int c=0;c<ch;c++) memcpy(buf[c],data,(size_t)len*sizeof(float));
  vorbis_analysis_wrote(&vd,len); vorbis_analysis_wrote(&vd,0);
  while(vorbis_analysis_blockout(&vd,&vb)==1){
    vorbis_analysis(&vb,NULL); vorbis_bitrate_addblock(&vb);
    while(vorbis_bitrate_flushpacket(&vd,&op)){
      ogg_stream_packetin(&os,&op);
      while(!eos){int r=ogg_stream_pageout(&os,&og); if(!r)break;
        fwrite(og.header,1,og.header_len,stdout);
        fwrite(og.body,1,og.body_len,stdout);
        if(ogg_page_eos(&og))eos=1;}}}
  ogg_stream_clear(&os); vorbis_block_clear(&vb); vorbis_dsp_clear(&vd);
  vorbis_comment_clear(&vc); vorbis_info_clear(&vi); free(data);
  return 0;
}
EOF

# Tiny decoder: writes raw little-endian float PCM (interleaved) to stdout.
cat >"$WORK/dec_dump.c" <<'EOF'
#include <vorbis/codec.h>
#include <ogg/ogg.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char**argv){
  FILE*f=fopen(argv[1],"rb");
  ogg_sync_state oy; ogg_stream_state os; ogg_page og; ogg_packet op;
  vorbis_info vi; vorbis_comment vc; vorbis_dsp_state vd; vorbis_block vb;
  ogg_sync_init(&oy); char*buf; int bytes;
  buf=ogg_sync_buffer(&oy,4096); bytes=(int)fread(buf,1,4096,f);
  ogg_sync_wrote(&oy,bytes);
  if(ogg_sync_pageout(&oy,&og)!=1) return 3;
  ogg_stream_init(&os,ogg_page_serialno(&og));
  vorbis_info_init(&vi); vorbis_comment_init(&vc);
  ogg_stream_pagein(&os,&og); ogg_stream_packetout(&os,&op);
  vorbis_synthesis_headerin(&vi,&vc,&op);
  int i=0;
  while(i<2){
    while(i<2){int r=ogg_sync_pageout(&oy,&og); if(r==0)break;
      if(r==1){ogg_stream_pagein(&os,&og);
        while(i<2){r=ogg_stream_packetout(&os,&op); if(r==0)break;
          if(r<0)return 4; vorbis_synthesis_headerin(&vi,&vc,&op); i++;}}}
    buf=ogg_sync_buffer(&oy,4096); bytes=(int)fread(buf,1,4096,f);
    if(bytes==0&&i<2)return 5; ogg_sync_wrote(&oy,bytes);
  }
  vorbis_synthesis_init(&vd,&vi); vorbis_block_init(&vd,&vb);
  int eos=0;
  while(!eos){
    while(!eos){int r=ogg_sync_pageout(&oy,&og); if(r==0)break;
      if(r<0)continue; ogg_stream_pagein(&os,&og);
      while(1){r=ogg_stream_packetout(&os,&op); if(r==0)break; if(r<0)continue;
        if(vorbis_synthesis(&vb,&op)==0) vorbis_synthesis_blockin(&vd,&vb);
        float **pcm; int s;
        while((s=vorbis_synthesis_pcmout(&vd,&pcm))>0){
          for(int fr=0;fr<s;fr++)
            for(int c=0;c<vi.channels;c++){
              union{float f;unsigned u;}x; x.f=pcm[c][fr];
              fwrite(&x.u,4,1,stdout);}
          vorbis_synthesis_read(&vd,s);}}
      if(ogg_page_eos(&og))eos=1;}
    if(!eos){buf=ogg_sync_buffer(&oy,4096);
      bytes=(int)fread(buf,1,4096,f); ogg_sync_wrote(&oy,bytes);
      if(bytes==0)eos=1;}
  }
  ogg_stream_clear(&os); vorbis_block_clear(&vb); vorbis_dsp_clear(&vd);
  vorbis_comment_clear(&vc); vorbis_info_clear(&vi); ogg_sync_clear(&oy);
  fclose(f); return 0;
}
EOF

build_variant() {
  local src="$1" build="$2"
  cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Debug \
    -DOGG_INCLUDE_DIR="$OGG_INCLUDE_DIR" -DOGG_LIBRARY="$OGG_LIBRARY" >/dev/null
  cmake --build "$build" -j"$(nproc)" >/dev/null
  gcc -O2 -I"$src/include" -I"$OGG_INCLUDE_DIR" \
      "$WORK/enc_dump.c" "$build/lib/libvorbisenc.a" "$build/lib/libvorbis.a" \
      "$OGG_LIBRARY" -lm -o "$build/enc_dump"
  gcc -O2 -I"$src/include" -I"$OGG_INCLUDE_DIR" \
      "$WORK/dec_dump.c" "$build/lib/libvorbis.a" \
      "$OGG_LIBRARY" -lm -o "$build/dec_dump"
}

section "Preparing pristine reference sources (HEAD, before the fix)"
git -C "$REPO_ROOT" worktree add --detach "$REF_SRC" HEAD >/dev/null

section "Building reference and candidate libraries"
build_variant "$REF_SRC" "$REF_BUILD"
build_variant "$REPO_ROOT" "$CAND_BUILD"

section "Comparing all 528 encode/decode cases (Ogg bytes + decoded PCM)"
mkdir -p "$WORK/ref" "$WORK/cand"
rates=(44100 48000 32000 22050 16000 96000)
count=0; failures=0
for ch in $(seq 1 8); do
  for qi in $(seq 0 10); do
    q="$(awk -v i=$qi 'BEGIN{printf "%.1f", -0.05 + 0.1*i}')"
    for rate in "${rates[@]}"; do
      name="c${ch}_q${q}_r${rate}.ogg"
      "$REF_BUILD/enc_dump"  "$ch" "$rate" "$q" >"$WORK/ref/$name"
      "$CAND_BUILD/enc_dump" "$ch" "$rate" "$q" >"$WORK/cand/$name"
      "$REF_BUILD/dec_dump"  "$WORK/ref/$name"  >"$WORK/ref/$name.pcm"
      "$CAND_BUILD/dec_dump" "$WORK/cand/$name" >"$WORK/cand/$name.pcm"
      count=$((count+1))
      if ! cmp -s "$WORK/ref/$name" "$WORK/cand/$name"; then
        echo "OGG BYTE DIFF: $name"; failures=$((failures+1));
      fi
      if ! cmp -s "$WORK/ref/$name.pcm" "$WORK/cand/$name.pcm"; then
        echo "PCM SAMPLE DIFF: $name"; failures=$((failures+1));
      fi
    done
  done
done

git -C "$REPO_ROOT" worktree remove --force "$REF_SRC" >/dev/null

if [[ "$failures" -ne 0 ]]; then
  echo "OUTPUT IDENTITY: FAIL ($failures differing cases of $count)" >&2
  exit 1
fi
section "OUTPUT IDENTITY: PASS - $count cases, Ogg bytes and PCM samples identical"
