/*
 * Overwrite model: a TCP sender streams a pattern, the receiver calls the
 * shim's sys_recvfile() per request the way smbd does (non-blocking socket,
 * blocking retry after EAGAIN), then checks the file contents.
 *
 * usage: sim-overwrite <shim.so> <file> <total_MiB> <req_KiB> <chunk_bytes> [MiB/s]
 *   chunk_bytes: size of each send() with TCP_NODELAY (small = many segments)
 *   MiB/s: sender pacing (e.g. 110 for gigabit), so the receiver catches up
 *   and gets whatever has arrived, as on the NAS
 * Measure device reads around it to see read-modify-write of uncached pages.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef ssize_t (*recvfile_fn)(int, int, off_t, size_t);
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %d: %s errno=%d\n", __LINE__, #x, errno); exit(1); } } while (0)

static unsigned char pat(unsigned long long off)
{
	return (unsigned char)((off * 2654435761ULL) >> 13 ^ off >> 20);
}

int main(int argc, char **argv)
{
	struct sockaddr_in a = { .sin_family = AF_INET };
	socklen_t al = sizeof(a);
	unsigned long long total, req, chunk, off;
	int ls, s, fd, one = 1, status;
	recvfile_fn recvfile;
	struct timespec t0, t1;
	struct rusage ru;
	unsigned char *buf;
	pid_t child;
	void *lib;
	double rate = 0;

	if (argc != 6 && argc != 7)
		return 2;
	if (argc == 7)
		rate = strtod(argv[6], NULL) * (1 << 20);
	total = strtoull(argv[3], NULL, 0) << 20;
	req = strtoull(argv[4], NULL, 0) << 10;
	chunk = strtoull(argv[5], NULL, 0);
	lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL); CHECK(lib);
	recvfile = (recvfile_fn)dlvsym(lib, "sys_recvfile", "SMBCONF_0.0.1"); CHECK(recvfile);

	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	ls = socket(AF_INET, SOCK_STREAM, 0); CHECK(ls >= 0);
	CHECK(bind(ls, (struct sockaddr *)&a, sizeof(a)) == 0);
	CHECK(listen(ls, 1) == 0);
	CHECK(getsockname(ls, (struct sockaddr *)&a, &al) == 0);

	child = fork(); CHECK(child >= 0);
	if (!child) {
		unsigned char *p = malloc(chunk);
		int c = socket(AF_INET, SOCK_STREAM, 0);

		CHECK(p && c >= 0);
		CHECK(setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) == 0);
		CHECK(connect(c, (struct sockaddr *)&a, sizeof(a)) == 0);
		clock_gettime(CLOCK_MONOTONIC, &t0);
		for (off = 0; off < total;) {
			unsigned long long n = total - off < chunk ? total - off : chunk, i;
			ssize_t w;

			for (i = 0; i < n; i++)
				p[i] = pat(off + i);
			w = write(c, p, n);
			if (w < 0 && errno == EINTR)
				continue;
			CHECK(w > 0);
			off += (unsigned long long)w;
			if (rate > 0) {
				/* sleep until the paced send time of off */
				double due = (double)off / rate, now;

				clock_gettime(CLOCK_MONOTONIC, &t1);
				now = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9;
				if (due - now > 50e-6) {
					struct timespec d = { (time_t)(due - now), (long)((due - now - (double)(time_t)(due - now)) * 1e9) };

					nanosleep(&d, NULL);
				}
			}
		}
		close(c);
		_exit(0);
	}
	s = accept(ls, NULL, NULL); CHECK(s >= 0);
	CHECK(fcntl(s, F_SETFL, O_NONBLOCK) == 0);
	fd = open(argv[2], O_WRONLY); CHECK(fd >= 0);

	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (off = 0; off < total; off += req) {
		unsigned long long done = 0;

		while (done < req) {
			ssize_t n = recvfile(s, fd, (off_t)(off + done), req - done);

			if (n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
				/* smbd vfs_pwrite_data: blocking retry */
				CHECK(fcntl(s, F_SETFL, 0) == 0);
				n = recvfile(s, fd, (off_t)(off + done), req - done);
				CHECK(fcntl(s, F_SETFL, O_NONBLOCK) == 0);
			}
			CHECK(n > 0);
			done += (unsigned long long)n;
		}
	}
	CHECK(fdatasync(fd) == 0);
	clock_gettime(CLOCK_MONOTONIC, &t1);
	CHECK(getrusage(RUSAGE_SELF, &ru) == 0);
	CHECK(waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status));
	close(fd);

	/* verify through a fresh descriptor */
	buf = malloc(1 << 20); CHECK(buf);
	fd = open(argv[2], O_RDONLY); CHECK(fd >= 0);
	for (off = 0; off < total; off += 1 << 20) {
		unsigned long long i;

		CHECK(pread(fd, buf, 1 << 20, (off_t)off) == 1 << 20);
		for (i = 0; i < 1 << 20; i++)
			if (buf[i] != pat(off + i)) {
				fprintf(stderr, "MISMATCH at %llu\n", off + i);
				return 1;
			}
	}
	/* receiver CPU per GiB (the sender is a separate process) */
	printf("ok %.1f MiB/s usr %.3f sys %.3f s/GiB\n", (double)total / (1 << 20) /
	       ((double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) / 1e9),
	       (double)(ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6) * (1 << 30) / (double)total,
	       (double)(ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6) * (1 << 30) / (double)total);
	return 0;
}
