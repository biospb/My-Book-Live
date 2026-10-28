/* 1 KiB appends, separate fsync time, then cold byte-for-byte readback. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
	struct timespec t;
	assert(clock_gettime(CLOCK_MONOTONIC,&t)==0);
	return t.tv_sec+t.tv_nsec/1e9;
}
static double seconds(struct timeval t) { return t.tv_sec+t.tv_usec/1e6; }
static unsigned char pattern[1024], actual[1024*1024];
int main(int argc,char **argv)
{
	char path[256];
	struct rusage before, after;
	struct stat st;
	const uint64_t records=65536;
	double start, written, flushed;
	int fd;
	assert(argc==2 && !strcmp(argv[1],"/DataVolume"));
	assert(snprintf(path,sizeof(path),"%s/mbl-append-bench-XXXXXX",argv[1])<(int)sizeof(path));
	fd=mkstemp(path); assert(fd>=0);
	for (size_t j=0;j<sizeof(pattern);j++) pattern[j]=(unsigned char)(j*13+7);
	assert(getrusage(RUSAGE_SELF,&before)==0);
	start=now();
	for (uint64_t i=0;i<records;i++) {
		ssize_t n;
		memcpy(pattern,&i,sizeof(i));
		do { n=write(fd,pattern,sizeof(pattern)); } while(n<0 && errno==EINTR);
		assert(n==(ssize_t)sizeof(pattern));
	}
	written=now();
	assert(getrusage(RUSAGE_SELF,&after)==0);
	assert(fsync(fd)==0);
	flushed=now();
	assert(fstat(fd,&st)==0 && st.st_size==(off_t)(records*sizeof(pattern)));
	assert(posix_fadvise(fd,0,0,POSIX_FADV_DONTNEED)==0);
	assert(lseek(fd,0,SEEK_SET)==0);
	for (uint64_t first=0;first<records;first+=1024) {
		size_t have=0;
		while(have<sizeof(actual)) {
			ssize_t n=read(fd,actual+have,sizeof(actual)-have);
			if(n<0 && errno==EINTR) continue;
			assert(n>0); have+=(size_t)n;
		}
		for(uint64_t j=0;j<1024;j++) {
			uint64_t serial;
			memcpy(&serial,actual+j*1024,sizeof(serial));
			assert(serial==first+j);
			assert(memcmp(actual+j*1024+8,pattern+8,sizeof(pattern)-8)==0);
		}
	}
	assert(close(fd)==0 && unlink(path)==0);
	printf("{\"records\":%llu,\"record_bytes\":1024,\"MiB\":64,\"write_seconds\":%.6f,\"flush_seconds\":%.6f,\"write_MiB_s\":%.6f,\"user_seconds\":%.6f,\"system_seconds\":%.6f,\"all_bytes_match\":true,\"file_removed\":true}\n",
		(unsigned long long)records,written-start,flushed-written,64.0/(written-start),
		seconds(after.ru_utime)-seconds(before.ru_utime),seconds(after.ru_stime)-seconds(before.ru_stime));
	return 0;
}
