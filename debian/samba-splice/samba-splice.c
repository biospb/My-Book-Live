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
 * v3: only whole 16K-aligned file blocks are written from the pipe; the
 * unaligned tail stays in the pipe until more data arrives or the request
 * ends. Writing a partial block of an existing, uncached file makes ext4
 * read that block first (overwrite fell to ~34 MiB/s with v2). While a tail
 * is held, the socket is switched to blocking for the rest of the call and
 * restored on return.
 *
 * A non-blocking EAGAIN with nothing received returns -1; input failures
 * write the held tail first, then return -1 (EAGAIN: any progress).
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
#ifndef PIPE_SIZE
#define PIPE_SIZE (1024 * 1024)
#endif
/* Page size on the MBL kernels; also a multiple of the 4K ext4 block. */
#ifndef WRITE_ALIGN
#define WRITE_ALIGN (16 * 1024)
#endif

typedef ssize_t (*recvfile_fn)(int, int, off_t, size_t);

static int pipefd[2] = { -1, -1 };
static size_t pipe_size;
static bool splice_ok = true;

#ifdef SPLICE_STATS
/* Test builds only: how often the tail had to wait or was written unaligned. */
#include <stdio.h>
static unsigned long st_block, st_unaligned;
__attribute__((destructor)) static void st_print(void)
{
	fprintf(stderr, "splice-stats block=%lu unaligned=%lu\n", st_block, st_unaligned);
}
#define STAT(x) ((x)++)
#else
#define STAT(x) ((void)0)
#endif

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

static void pipe_reset(void)
{
	close(pipefd[0]);
	close(pipefd[1]);
	pipefd[0] = pipefd[1] = -1;
}

/*
 * Move len bytes from the pipe to the file at *offp. Returns false with errno
 * set on failure; *inpipe and *written always reflect what was moved.
 */
static bool to_file(int tofd, loff_t *offp, size_t len, size_t *inpipe, size_t *written)
{
	while (len > 0) {
		ssize_t out = splice(pipefd[0], NULL, tofd, offp, len, SPLICE_F_MOVE);

		if (out == -1 && errno == EINTR)
			continue;
		if (out <= 0) {
			if (out == 0)
				errno = EIO;
			return false;
		}
		len -= (size_t)out;
		*inpipe -= (size_t)out;
		*written += (size_t)out;
	}
	return true;
}

/* Input side failed or ended: write what is already in the pipe, keep errno. */
static void flush_on_input_error(int tofd, loff_t *offp, size_t *inpipe, size_t *written)
{
	int saved_errno = errno;

	if (*inpipe && !to_file(tofd, offp, *inpipe, inpipe, written) &&
	    !drain(pipefd[0], *inpipe))
		pipe_reset();
	errno = saved_errno;
}

static ssize_t splice_recv(int fromfd, int tofd, off_t offset, size_t count, int *sock_flags)
{
	loff_t off = offset;
	size_t written = 0, consumed = 0, inpipe = 0;
	int saved_errno;

	/*
	 * Bytes in the pipe always start at file offset off. Only whole
	 * WRITE_ALIGN blocks go to the file; the unaligned tail waits in the
	 * pipe for the next socket data, so writes into existing uncached
	 * pages do not end mid-block (that makes ext4 read the block first).
	 */
	while (consumed < count) {
		size_t want = count - consumed, tail, flush;
		ssize_t in;

		if (want > pipe_size - inpipe)
			want = pipe_size - inpipe;
		if (inpipe && *sock_flags == -1) {
			/*
			 * Keeping a tail: wait for the rest in the kernel instead of
			 * returning (smbd would switch the socket to blocking and
			 * call again anyway). Restored by sys_recvfile().
			 */
			int fl = fcntl(fromfd, F_GETFL);

			*sock_flags = -2;
			if (fl != -1 && (fl & O_NONBLOCK) &&
			    fcntl(fromfd, F_SETFL, fl & ~O_NONBLOCK) == 0) {
				*sock_flags = fl;
				STAT(st_block);
			}
		}
		/*
		 * With a tail kept in the pipe, its slots may all be taken
		 * (one slot per RX fragment); a blocking splice would then
		 * wait forever for ourselves. SPLICE_F_NONBLOCK applies to the
		 * pipe only, so EAGAIN here means the pipe is full (or the
		 * socket could not be made blocking).
		 */
		in = want == 0 ? (errno = EAGAIN, -1) :
		     splice(fromfd, NULL, pipefd[1], NULL, want,
			    SPLICE_F_MOVE | SPLICE_F_MORE | (inpipe ? SPLICE_F_NONBLOCK : 0));
		if (in == -1) {
			if (errno == EINTR)
				continue;
			if (consumed == 0 && (errno == EINVAL || errno == ENOSYS || errno == EBADF)) {
				/* no socket -> pipe splice here: never try again */
				splice_ok = false;
				return orig_recvfile(fromfd, tofd, offset, count);
			}
			if ((errno == EAGAIN || errno == EWOULDBLOCK) && inpipe) {
				/* write the tail unaligned and go on with an empty pipe */
				STAT(st_unaligned);
				if (!to_file(tofd, &off, inpipe, &inpipe, &written))
					goto out_error;
				continue;
			}
			flush_on_input_error(tofd, &off, &inpipe, &written);
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				return written ? (ssize_t)written : -1;
			return -1;
		}
		if (in == 0) {
			/* peer closed */
			flush_on_input_error(tofd, &off, &inpipe, &written);
			errno = ECONNRESET;
			return -1;
		}
		consumed += (size_t)in;
		inpipe += (size_t)in;
		if (consumed == count) {
			flush = inpipe;
		} else {
			tail = (size_t)((unsigned long long)(off + (loff_t)inpipe) % WRITE_ALIGN);
			flush = inpipe > tail ? inpipe - tail : 0;
		}
		if (flush && !to_file(tofd, &off, flush, &inpipe, &written))
			goto out_error;
	}
	return (ssize_t)written;

out_error:
	/* write error: empty the pipe, drop the rest of the data */
	saved_errno = errno;
	if (!drain(pipefd[0], inpipe) || !drain(fromfd, count - consumed)) {
		pipe_reset();
		return -1;
	}
	errno = saved_errno;
	return written ? (ssize_t)written : -1;
}

ssize_t sys_recvfile(int fromfd, int tofd, off_t offset, size_t count)
{
	int file_flags, sock_flags = -1, saved_errno;
	ssize_t ret;

	if (count == 0)
		return 0;
	if (!splice_ok || tofd == -1 ||
	    offset == VFS_PWRITE_APPEND_OFFSET)
		return orig_recvfile(fromfd, tofd, offset, count);
	/* splice rejects O_APPEND even when an explicit offset is supplied. */
	file_flags = fcntl(tofd, F_GETFL);
	if (file_flags == -1 || (file_flags & O_APPEND) || !pipe_setup())
		return orig_recvfile(fromfd, tofd, offset, count);

	ret = splice_recv(fromfd, tofd, offset, count, &sock_flags);
	if (sock_flags >= 0) {
		saved_errno = errno;
		fcntl(fromfd, F_SETFL, sock_flags);
		errno = saved_errno;
	}
	return ret;
}
