/*
 * samba-splice: LD_PRELOAD replacement for Samba's sys_recvfile() that uses
 * splice(2) socket -> pipe -> file instead of read(2) + write(2).
 *
 * Samba has the splice code (source3/lib/recvfile.c) but keeps it disabled
 * (try_splice_call = false), so "min receivefile size" only saves the SMB2
 * header parsing and still copies every byte twice (socket -> user -> page
 * cache). With splice the socket -> pipe step moves skb pages, only the
 * pipe -> page cache copy remains.
 *
 * A non-blocking EAGAIN returns any progress; other input failures return -1.
 * On output failure, return progress or -1 if none, with errno set; consume
 * the remaining request payload so the next SMB header stays framed.
 * Append/drain-only requests use Samba's original implementation.
 *
 * Build: see Makefile. Use: LD_PRELOAD=/usr/local/lib/samba-splice.so smbd
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdbool.h>
#include <sys/types.h>
#include <unistd.h>

#define VFS_PWRITE_APPEND_OFFSET ((off_t)-1)
#define PIPE_SIZE (1024 * 1024)

typedef ssize_t (*recvfile_fn)(int, int, off_t, size_t);

static int pipefd[2] = { -1, -1 };
static size_t pipe_size;
static bool splice_ok = true;

static ssize_t orig_recvfile(int fromfd, int tofd, off_t offset, size_t count)
{
	static recvfile_fn orig;

	if (!orig)
		orig = (recvfile_fn)dlvsym(RTLD_NEXT, "sys_recvfile", "SMBCONF_0.0.1");
	if (!orig) {
		errno = ENOSYS;
		return -1;
	}
	return orig(fromfd, tofd, offset, count);
}

static bool pipe_setup(void)
{
	int sz;

	if (pipefd[0] != -1)
		return true;
	if (pipe2(pipefd, O_CLOEXEC) == -1)
		return false;
	sz = fcntl(pipefd[1], F_SETPIPE_SZ, PIPE_SIZE);
	if (sz <= 0)
		sz = fcntl(pipefd[1], F_GETPIPE_SZ);
	pipe_size = sz > 0 ? (size_t)sz : 65536;
	return true;
}

/* Read and drop len bytes from fd (pipe or socket); returns false on error/EOF. */
static bool drain(int fd, size_t len)
{
	char buf[16384];

	while (len > 0) {
		ssize_t n = read(fd, buf, len < sizeof(buf) ? len : sizeof(buf));

		if (n == -1 && errno == EINTR)
			continue;
		if (n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
			struct pollfd p = { .fd = fd, .events = POLLIN };

			int ret;

			do {
				ret = poll(&p, 1, 60000);
			} while (ret == -1 && errno == EINTR);
			if (ret <= 0)
				return false;
			continue;
		}
		if (n <= 0)
			return false;
		len -= (size_t)n;
	}
	return true;
}

ssize_t sys_recvfile(int fromfd, int tofd, off_t offset, size_t count)
{
	loff_t off = offset;
	loff_t *offp = offset == VFS_PWRITE_APPEND_OFFSET ? NULL : &off;
	size_t written = 0, consumed = 0;
	int saved_errno = 0, file_flags;

	if (count == 0)
		return 0;
	if (!splice_ok || tofd == -1 ||
	    offset == VFS_PWRITE_APPEND_OFFSET)
		return orig_recvfile(fromfd, tofd, offset, count);
	/* splice rejects O_APPEND even when an explicit offset is supplied. */
	file_flags = fcntl(tofd, F_GETFL);
	if (file_flags == -1 || (file_flags & O_APPEND) || !pipe_setup())
		return orig_recvfile(fromfd, tofd, offset, count);

	while (consumed < count) {
		size_t want = count - consumed;
		ssize_t in, left;

		if (want > pipe_size)
			want = pipe_size;
		in = splice(fromfd, NULL, pipefd[1], NULL, want, SPLICE_F_MOVE | SPLICE_F_MORE);
		if (in == -1) {
			if (errno == EINTR)
				continue;
			if (consumed == 0 && (errno == EINVAL || errno == ENOSYS || errno == EBADF)) {
				/* no socket -> pipe splice here: never try again */
				splice_ok = false;
				return orig_recvfile(fromfd, tofd, offset, count);
			}
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				return written ? (ssize_t)written : -1;
			return -1;
		}
		if (in == 0) {
			/* peer closed */
			errno = ECONNRESET;
			return -1;
		}
		consumed += (size_t)in;
		for (left = in; left > 0;) {
			ssize_t out = splice(pipefd[0], NULL, tofd, offp, (size_t)left, SPLICE_F_MOVE);

			if (out == -1 && errno == EINTR)
				continue;
			if (out <= 0) {
				/* write error: empty the pipe, drop the rest of the data */
				saved_errno = out == 0 ? EIO : errno;
				if (!drain(pipefd[0], (size_t)left) ||
				    !drain(fromfd, count - consumed)) {
					close(pipefd[0]);
					close(pipefd[1]);
					pipefd[0] = pipefd[1] = -1;
					return -1;
				}
				errno = saved_errno;
				return written ? (ssize_t)written : -1;
			}
			left -= out;
			written += (size_t)out;
		}
	}
	return (ssize_t)written;
}
