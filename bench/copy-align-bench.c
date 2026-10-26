/* Diagnostic microbenchmark: the normal write/uaccess path into tmpfs pages.
 * No direct DMA, no service changes; creates and immediately unlinks one file.
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/statvfs.h>
#include <time.h>
#include <unistd.h>

#define CHUNK (16U * 1024U)
#define SOURCE (128U * 1024U)
#define WINDOW (32U * 1024U * 1024U)
#define VOLUME (1024ULL * 1024ULL * 1024ULL)

static void die(const char *what)
{
	perror(what);
	exit(1);
}

static double seconds(void)
{
	struct timespec t;
	if (clock_gettime(CLOCK_MONOTONIC, &t)) die("clock_gettime");
	return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static void write_chunk(int fd, const unsigned char *p, size_t size)
{
	while (size) {
		ssize_t n = write(fd, p, size);
		if (n < 0 && errno == EINTR) continue;
		if (n <= 0) die("write");
		p += n;
		size -= n;
	}
}

int main(void)
{
	const unsigned int offsets[] = {0, 24, 24, 0, 0, 24};
	char path[] = "/dev/shm/mbl-copy-align-XXXXXX";
	unsigned char *buffer, *check;
	struct statvfs space;
	uint32_t seed = 0x12345678U;
	unsigned int i, run;
	int fd;
	if (statvfs("/dev/shm", &space)) die("statvfs");
	if ((uint64_t)space.f_bavail * space.f_frsize < 2ULL * WINDOW) {
		fprintf(stderr, "Need at least 64 MiB free in /dev/shm\n");
		return 1;
	}
	if (posix_memalign((void **)&buffer, 4096, SOURCE + 32) ||
	    posix_memalign((void **)&check, 4096, SOURCE)) {
		fprintf(stderr, "Allocation failed\n");
		return 1;
	}
	for (i = 0; i < SOURCE + 32; i++) {
		seed = seed * 1664525U + 1013904223U;
		buffer[i] = (unsigned char)(seed >> 24);
	}
	fd = mkstemp(path);
	if (fd < 0) die("mkstemp");
	if (unlink(path)) die("unlink");
	/* Allocate and fault in destination pages before any timed pass. */
	for (i = 0; i < WINDOW; i += CHUNK)
		write_chunk(fd, buffer + i % SOURCE, CHUNK);
	for (run = 0; run < sizeof(offsets)/sizeof(offsets[0]); run++) {
		unsigned int offset = offsets[run];
		uint64_t done;
		double start, elapsed;
		if (lseek(fd, 0, SEEK_SET) < 0) die("lseek");
		start = seconds();
		for (done = 0; done < VOLUME; done += CHUNK) {
			if (done && done % WINDOW == 0 && lseek(fd, 0, SEEK_SET) < 0)
				die("lseek");
			write_chunk(fd, buffer + offset + done % SOURCE, CHUNK);
		}
		elapsed = seconds() - start;
		if (lseek(fd, 0, SEEK_SET) < 0) die("lseek");
		for (i = 0; i < WINDOW; i += SOURCE) {
			size_t have = 0;
			while (have < SOURCE) {
				ssize_t n = read(fd, check + have, SOURCE - have);
				if (n < 0 && errno == EINTR) continue;
				if (n <= 0) die("readback");
				have += n;
			}
			if (memcmp(check, buffer + offset, SOURCE)) {
				fprintf(stderr, "Readback mismatch\n");
				return 1;
			}
		}
		printf("{\"run\":%u,\"offset\":%u,\"bytes\":%llu,\"seconds\":%.6f,\"MiB_s\":%.6f,\"data_ok\":true}\n",
		       run + 1, offset, (unsigned long long)VOLUME, elapsed,
		       (double)VOLUME / (1024.0 * 1024.0) / elapsed);
		fflush(stdout);
	}
	if (close(fd)) die("close");
	free(buffer);
	free(check);
	return 0;
}
