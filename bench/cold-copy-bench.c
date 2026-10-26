/* Isolated RAM benchmark: real kernel PPC copy loops, no DMA or kernel edits. */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define SLOTS 16384U
#define STRIDE 2048U
#define PAYLOAD 1460U
#define OFFSET 56U
#define PASSES 32U
extern void *mbl_kernel_memcpy(void *,const void *,size_t);
extern unsigned long mbl_bounded_copy(void *,const void *,size_t);

static double now(void)
{
	struct timespec t;
	if(clock_gettime(CLOCK_MONOTONIC,&t)) {perror("clock");exit(1);}
	return t.tv_sec+t.tv_nsec*1e-9;
}
int main(int argc,char **argv)
{
	/* Three balanced rounds; last reverses order to expose simple drift. */
	const unsigned int order[]={0,1,2, 1,2,0, 2,1,0};
	const unsigned int hot_order[]={0,3,3,0,0,3};
	const char *names[]={"hot-memcpy","cold-memcpy","cold-bounded","hot-bounded"};
	const unsigned int *selected=order;
	unsigned int runs=sizeof(order)/sizeof(order[0]);
	unsigned char *source,*dest;
	uint32_t seed=0x12345678U;
	unsigned int run,i,pass;
	size_t source_size=(size_t)SLOTS*STRIDE;
	size_t data_size=(size_t)SLOTS*PAYLOAD;
	if(argc==2 && !strcmp(argv[1],"--hot")) {selected=hot_order;runs=sizeof(hot_order)/sizeof(hot_order[0]);}
	else if(argc!=1) return 1;
	if(posix_memalign((void **)&source,4096,source_size) ||
	   posix_memalign((void **)&dest,4096,data_size+4096)) return 1;
	for(i=0;i<source_size;i++) {
		seed=seed*1664525U+1013904223U;
		source[i]=(unsigned char)(seed>>24);
	}
	/* Check the exported loops before timing, on the alignment class used
	 * by the RX benchmark, including byte tails and zero-length copies. */
	{
		const unsigned int lengths[]={0,1,3,4,31,32,127,1460,4096};
		unsigned int kind,off,l,j;
		for(kind=0;kind<2;kind++) for(off=0;off<32;off+=4)
			for(l=0;l<sizeof(lengths)/sizeof(lengths[0]);l++) {
				unsigned int n=lengths[l];
				memset(dest,0xa5,8192);
				if(kind) { if(mbl_bounded_copy(dest+off,source+OFFSET,n)) return 5; }
				else mbl_kernel_memcpy(dest+off,source+OFFSET,n);
				if(memcmp(dest+off,source+OFFSET,n)) return 6;
				for(j=0;j<8192;j++)
					if((j<off || j>=off+n) && dest[j]!=0xa5) return 7;
			}
		fprintf(stderr,"PREFLIGHT OK: two loops, 8 alignments, 9 lengths, guards\n");
	}
	memset(dest,0xa5,data_size+4096);
	for(run=0;run<runs;run++) {
		unsigned int mode=selected[run], source_slots=(mode==0 || mode==3) ? 64U : SLOTS;
		double start=now(),elapsed;
		for(pass=0;pass<PASSES;pass++)
			for(i=0;i<SLOTS;i++) {
				const void *from=source+(i%source_slots)*STRIDE+OFFSET;
				void *to=dest+(size_t)i*PAYLOAD;
				if(mode>=2) {
					if(mbl_bounded_copy(to,from,PAYLOAD)) return 2;
				} else mbl_kernel_memcpy(to,from,PAYLOAD);
			}
		elapsed=now()-start;
		for(i=0;i<SLOTS;i++)
			if(memcmp(dest+(size_t)i*PAYLOAD,source+(i%source_slots)*STRIDE+OFFSET,PAYLOAD)) {
				fprintf(stderr,"Data mismatch mode=%u slot=%u\n",mode,i);return 3;
			}
		for(i=0;i<4096;i++)
			if(dest[data_size+i]!=0xa5) {fprintf(stderr,"Guard mismatch\n");return 4;}
		printf("{\"run\":%u,\"mode\":\"%s\",\"source_bytes\":%u,\"bytes\":%llu,\"seconds\":%.6f,\"MiB_s\":%.6f,\"data_ok\":true,\"guard_ok\":true}\n",
		       run+1,names[mode],source_slots*STRIDE,
		       (unsigned long long)data_size*PASSES,elapsed,data_size*(double)PASSES/1048576.0/elapsed);
		fflush(stdout);
	}
	free(source);free(dest);
	return 0;
}
