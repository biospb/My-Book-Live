/* Test bounded prefetch distances in valid RAM; never patches the kernel. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern unsigned long mbl_pf1(void *,const void *,size_t);
extern unsigned long mbl_pf2(void *,const void *,size_t);
extern unsigned long mbl_pf4(void *,const void *,size_t);
extern unsigned long mbl_pf8(void *,const void *,size_t);
typedef unsigned long (*copy_fn)(void *,const void *,size_t);
static copy_fn functions[]={mbl_pf1,mbl_pf2,mbl_pf4,mbl_pf8};
static const unsigned int distances[]={1,2,4,8};
struct workload { const char *name; unsigned int size,stride,offset,slots,source_slots,passes; };
static const struct workload work[]={
	{"rx-cold",1460,2048,56,16384,16384,12},
	{"rx-hot",1460,2048,56,16384,64,12},
	{"page-cold",16384,16384,24,2048,2048,8},
	{"page-hot",16384,16384,24,2048,8,8},
};
static double now(void)
{
	struct timespec t;
	if(clock_gettime(CLOCK_MONOTONIC,&t)) {perror("clock");exit(1);}
	return t.tv_sec+t.tv_nsec*1e-9;
}
static int copy_pass(copy_fn fn,unsigned char *dst,const unsigned char *src,const struct workload *w)
{
	unsigned int i;
	for(i=0;i<w->slots;i++)
		if(fn(dst+(size_t)i*w->size,src+(size_t)(i%w->source_slots)*w->stride+w->offset,w->size)) return 1;
	return 0;
}
int main(void)
{
	const size_t allocation=32U*1024U*1024U+4096;
	const unsigned int lengths[]={0,1,3,4,7,15,31,32,33,63,64,65,127,128,129,255,256,257,511,512,513,1460,1461,4096,16384};
	unsigned char *src,*dst;
	uint32_t seed=0x12345678U;
	unsigned int f,i,s,d,l,round,position,k,pass,checks=0;
	if(posix_memalign((void **)&src,4096,allocation) || posix_memalign((void **)&dst,4096,allocation)) return 1;
	for(i=0;i<allocation;i++) {seed=seed*1664525U+1013904223U;src[i]=(unsigned char)(seed>>24);}
	memset(dst,0xa5,allocation);
	for(f=0;f<4;f++) for(s=0;s<32;s+=4) for(d=0;d<32;d+=4)
	for(l=0;l<sizeof(lengths)/sizeof(lengths[0]);l++) {
		unsigned int n=lengths[l];
		memset(dst,0xa5,n+128);
		if(functions[f](dst+d,src+s,n) || memcmp(dst+d,src+s,n)) return 2;
		for(i=0;i<d;i++) if(dst[i]!=0xa5) return 3;
		for(i=d+n;i<d+n+64;i++) if(dst[i]!=0xa5) return 4;
		checks++;
	}
	fprintf(stderr,"PREFLIGHT OK: %u cases, all variants, data and guards\n",checks);
	/* Latin rotation balances distance position and workload position. */
	for(round=0;round<4;round++) for(k=0;k<4;k++) {
		const struct workload *w=&work[(round+k)%4];
		size_t bytes=(size_t)w->slots*w->size;
		for(position=0;position<4;position++) {
			double start,elapsed;
			f=(round+position)%4;
			memset(dst,0xa5,bytes+64);
			if(copy_pass(functions[f],dst,src,w)) return 5;
			start=now();
			for(pass=0;pass<w->passes;pass++) if(copy_pass(functions[f],dst,src,w)) return 6;
			elapsed=now()-start;
			for(i=0;i<w->slots;i++)
				if(memcmp(dst+(size_t)i*w->size,src+(size_t)(i%w->source_slots)*w->stride+w->offset,w->size)) return 7;
			for(i=0;i<64;i++) if(dst[bytes+i]!=0xa5) return 8;
			printf("{\"round\":%u,\"workload\":\"%s\",\"distance_lines\":%u,\"bytes\":%llu,\"seconds\":%.6f,\"MiB_s\":%.6f,\"data_ok\":true,\"guard_ok\":true}\n",
			       round+1,w->name,distances[f],(unsigned long long)bytes*w->passes,elapsed,bytes*(double)w->passes/1048576.0/elapsed);
			fflush(stdout);
		}
	}
	free(src);free(dst);
	return 0;
}
