/********************************************************************
 *                                                                  *
 * THIS FILE IS PART OF THE OggVorbis SOFTWARE CODEC SOURCE CODE.   *
 * USE, DISTRIBUTION AND REPRODUCTION OF THIS LIBRARY SOURCE IS     *
 * GOVERNED BY A BSD-STYLE SOURCE LICENSE INCLUDED WITH THIS SOURCE *
 * IN 'COPYING'. PLEASE READ THESE TERMS BEFORE DISTRIBUTING.       *
 *                                                                  *
 ********************************************************************

 function: repeatable decode benchmark with pass/fail thresholds.

 Generates a small, fully deterministic Ogg Vorbis asset in memory
 (fixed PCM, fixed encoder settings, fixed stream serial number),
 decodes it repeatedly through vorbisfile, and reports wall-clock
 decode time and peak resident memory.  The run fails (non-zero
 exit) when either metric exceeds its threshold, so it can run as
 part of the regular test suite (ctest / make check).

 Thresholds are calibrated for the reference machine recorded in
 output/benchmark.md and carry generous headroom; both can be
 overridden with the environment variables BENCH_MAX_DECODE_MS and
 BENCH_MAX_RSS_KB without recompiling.

 This program only exercises the public library API; it does not
 modify library behavior.

 ********************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <sys/resource.h>

#include <vorbis/vorbisenc.h>
#include <vorbis/vorbisfile.h>

/* ----- fixed asset parameters (do not change: keeps the benchmark
   comparable across runs) ----- */
#define SAMPLE_RATE   44100
#define CHANNELS      2
#define DURATION_SEC  2
#define PCM_FRAMES    (SAMPLE_RATE * DURATION_SEC)
#define ENCODE_QUALITY 0.4f
#define STREAM_SERIAL  0x4F474753 /* fixed serial: deterministic asset */

/* ----- benchmark parameters ----- */
#define DECODE_ITERS  25

/* ----- pass/fail thresholds (defaults; env overrides allowed) ----- */
#define DEFAULT_MAX_DECODE_MS 500.0 /* total wall time for all iterations */
#define DEFAULT_MAX_RSS_KB    (64L*1024L) /* peak RSS, 64 MB */

static double now_ms(void){
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC,&ts);
  return ts.tv_sec*1000.0 + ts.tv_nsec/1e6;
}

static long peak_rss_kb(void){
  struct rusage ru;
  getrusage(RUSAGE_SELF,&ru);
  return ru.ru_maxrss; /* kilobytes on Linux */
}

/* deterministic test signal: fixed sum of sines, no RNG */
static void gen_pcm(float **pcm){
  int i;
  for(i=0;i<PCM_FRAMES;i++){
    double t=(double)i/SAMPLE_RATE;
    pcm[0][i]=(float)(0.30*sin(2.0*M_PI*440.0*t)+
                      0.20*sin(2.0*M_PI*554.37*t)+
                      0.10*sin(2.0*M_PI*659.26*t));
    pcm[1][i]=(float)(0.30*sin(2.0*M_PI*440.0*t+0.5)+
                      0.20*sin(2.0*M_PI*554.37*t+0.25)+
                      0.10*sin(2.0*M_PI*659.26*t+0.75));
  }
}

/* growable byte buffer holding the encoded asset */
typedef struct {
  unsigned char *data;
  size_t len, cap;
} buffer_t;

static void buffer_append(buffer_t *b,const void *p,size_t n){
  if(b->len+n>b->cap){
    b->cap=(b->cap?b->cap*2:16384);
    while(b->cap<b->len+n)b->cap*=2;
    b->data=realloc(b->data,b->cap);
    if(!b->data){fprintf(stderr,"out of memory\n");exit(2);}
  }
  memcpy(b->data+b->len,p,n);
  b->len+=n;
}

/* encode the fixed PCM into an in-memory Ogg Vorbis stream */
static void encode_asset(buffer_t *out){
  vorbis_info vi;
  vorbis_comment vc;
  vorbis_dsp_state vd;
  vorbis_block vb;
  ogg_stream_state os;
  ogg_page og;
  ogg_packet op, header, header_comm, header_code;
  float *pcm[CHANNELS];
  int i, eos=0;

  pcm[0]=malloc(sizeof(float)*PCM_FRAMES);
  pcm[1]=malloc(sizeof(float)*PCM_FRAMES);
  if(!pcm[0]||!pcm[1]){fprintf(stderr,"out of memory\n");exit(2);}
  gen_pcm(pcm);

  vorbis_info_init(&vi);
  if(vorbis_encode_init_vbr(&vi,CHANNELS,SAMPLE_RATE,ENCODE_QUALITY)){
    fprintf(stderr,"encode init failed\n");exit(2);
  }
  vorbis_comment_init(&vc);
  vorbis_analysis_init(&vd,&vi);
  vorbis_block_init(&vd,&vb);
  ogg_stream_init(&os,STREAM_SERIAL);

  vorbis_analysis_headerout(&vd,&vc,&header,&header_comm,&header_code);
  ogg_stream_packetin(&os,&header);
  ogg_stream_packetin(&os,&header_comm);
  ogg_stream_packetin(&os,&header_code);
  while(ogg_stream_flush(&os,&og)){
    buffer_append(out,og.header,og.header_len);
    buffer_append(out,og.body,og.body_len);
  }

  i=0;
  while(!eos){
    long n=PCM_FRAMES-i;
    if(n>1024)n=1024;
    if(n<=0){
      vorbis_analysis_wrote(&vd,0);
    }else{
      float **buf=vorbis_analysis_buffer(&vd,n);
      memcpy(buf[0],pcm[0]+i,sizeof(float)*n);
      memcpy(buf[1],pcm[1]+i,sizeof(float)*n);
      vorbis_analysis_wrote(&vd,n);
      i+=n;
    }
    while(vorbis_analysis_blockout(&vd,&vb)==1){
      vorbis_analysis(&vb,NULL);
      vorbis_bitrate_addblock(&vb);
      while(vorbis_bitrate_flushpacket(&vd,&op)){
        ogg_stream_packetin(&os,&op);
        while(!eos){
          if(!ogg_stream_pageout(&os,&og))break;
          buffer_append(out,og.header,og.header_len);
          buffer_append(out,og.body,og.body_len);
          if(ogg_page_eos(&og))eos=1;
        }
      }
    }
  }

  ogg_stream_clear(&os);
  vorbis_block_clear(&vb);
  vorbis_dsp_clear(&vd);
  vorbis_comment_clear(&vc);
  vorbis_info_clear(&vi);
  free(pcm[0]);
  free(pcm[1]);
}

/* ----- memory-backed vorbisfile callbacks ----- */
typedef struct {
  const unsigned char *data;
  size_t len, pos;
} memsrc_t;

static size_t mem_read(void *ptr,size_t size,size_t nmemb,void *src){
  memsrc_t *m=src;
  size_t want=size*nmemb, left=m->len-m->pos;
  if(want>left)want=left;
  memcpy(ptr,m->data+m->pos,want);
  m->pos+=want;
  return size?want/size:0;
}
static int mem_seek(void *src,ogg_int64_t off,int whence){
  memsrc_t *m=src;
  ogg_int64_t np;
  switch(whence){
  case SEEK_SET: np=off; break;
  case SEEK_CUR: np=(ogg_int64_t)m->pos+off; break;
  case SEEK_END: np=(ogg_int64_t)m->len+off; break;
  default: return -1;
  }
  if(np<0||(ogg_uint64_t)np>m->len)return -1;
  m->pos=(size_t)np;
  return 0;
}
static long mem_tell(void *src){
  return (long)((memsrc_t*)src)->pos;
}

static unsigned long long fnv1a(const unsigned char *p,long n,
                                unsigned long long h){
  long i;
  for(i=0;i<n;i++){h^=p[i];h*=1099511628211ULL;}
  return h;
}

/* decode the whole asset once; returns decoded bytes, updates hash */
static long decode_once(const buffer_t *asset,unsigned long long *hash){
  static const ov_callbacks cb={mem_read,mem_seek,NULL,mem_tell};
  memsrc_t m={asset->data,asset->len,0};
  OggVorbis_File vf;
  char buf[4096];
  long total=0, r;
  int sec;
  unsigned long long h=1469598103934665603ULL;

  if(ov_open_callbacks(&m,&vf,NULL,0,cb)<0){
    fprintf(stderr,"ov_open_callbacks failed\n");
    exit(2);
  }
  while((r=ov_read(&vf,buf,sizeof(buf),0,2,1,&sec))>0){
    h=fnv1a((unsigned char*)buf,r,h);
    total+=r;
  }
  if(r<0){
    fprintf(stderr,"decode error %ld\n",r);
    exit(2);
  }
  ov_clear(&vf);
  if(hash)*hash=h;
  return total;
}

static double env_or_default(const char *name,double fallback){
  const char *v=getenv(name);
  if(v&&*v)return strtod(v,NULL);
  return fallback;
}

int main(void){
  buffer_t asset={NULL,0,0};
  double max_decode_ms=env_or_default("BENCH_MAX_DECODE_MS",
                                      DEFAULT_MAX_DECODE_MS);
  double max_rss_kb=env_or_default("BENCH_MAX_RSS_KB",
                                   DEFAULT_MAX_RSS_KB);
  double t0,t1,best=1e30;
  long pcm_bytes=0,rss_kb;
  unsigned long long hash=0,hash2=0;
  int i,fail=0;

  encode_asset(&asset);
  fprintf(stderr,"asset: %zu bytes ogg (%d ch, %d Hz, %d s, q=%.1f)\n",
          asset.len,CHANNELS,SAMPLE_RATE,DURATION_SEC,
          (double)ENCODE_QUALITY);

  t0=now_ms();
  for(i=0;i<DECODE_ITERS;i++){
    double a=now_ms();
    long n=decode_once(&asset,i<2?(i==0?&hash:&hash2):NULL);
    double b=now_ms();
    if(b-a<best)best=b-a;
    if(i==0)pcm_bytes=n;
    else if(n!=pcm_bytes){
      fprintf(stderr,"FAIL: non-deterministic decode size %ld != %ld\n",
              n,pcm_bytes);
      return 1;
    }
  }
  t1=now_ms();
  rss_kb=peak_rss_kb();

  fprintf(stderr,"decode: %d iters, %ld pcm bytes/iter\n",
          DECODE_ITERS,pcm_bytes);
  fprintf(stderr,"time:   total %.1f ms, best %.2f ms/iter "
          "(threshold total <= %.1f ms)\n",t1-t0,best,max_decode_ms);
  fprintf(stderr,"memory: peak rss %ld KB (threshold <= %.0f KB)\n",
          rss_kb,max_rss_kb);
  fprintf(stderr,"pcm hash: 0x%016llx\n",hash);

  if(t1-t0>max_decode_ms){
    fprintf(stderr,"FAIL: decode time %.1f ms exceeds threshold %.1f ms\n",
            t1-t0,max_decode_ms);
    fail=1;
  }
  if(rss_kb>max_rss_kb){
    fprintf(stderr,"FAIL: peak rss %ld KB exceeds threshold %.0f KB\n",
            rss_kb,max_rss_kb);
    fail=1;
  }
  if(hash!=hash2){
    fprintf(stderr,"FAIL: non-deterministic decode: hash run1 0x%016llx "
            "!= run2 0x%016llx (library output unstable)\n",hash,hash2);
    fail=1;
  }

  fprintf(stderr,"%s\n",fail?"BENCH: FAIL":"BENCH: PASS");
  free(asset.data);
  return fail;
}
