/* One-shot TCP -> ext4 comparison. Never overwrites an existing file. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *what) { perror(what); exit(1); }
static double now(void)
{
	struct timespec t;
	if (clock_gettime(CLOCK_MONOTONIC, &t)) fail("clock_gettime");
	return t.tv_sec + t.tv_nsec * 1e-9;
}
static void send_all(int fd, const char *p, size_t bytes)
{
	while (bytes) {
		ssize_t n = send(fd, p, bytes, MSG_NOSIGNAL);
		if (n < 0 && errno == EINTR) continue;
		if (n <= 0) fail("send");
		p += n; bytes -= n;
	}
}
int main(int argc, char **argv)
{
	struct sockaddr_in address = { .sin_family = AF_INET };
	struct timeval timeout = { .tv_sec = 120 };
	char file[] = "/DataVolume/mbl-splice-bench-XXXXXX";
	char *buffer, message[768], digest[65], command[80], go[3];
	const char *mode;
	int discard;
	uint64_t total, received = 0, in_calls = 0, out_calls = 0;
	size_t max_in = 0, pipe_bytes = 0;
	int listen_fd, sock, file_fd, pipes[2] = {-1, -1}, yes = 1;
	double start, elapsed, flush_start, flush_seconds;
	FILE *hash;
	if (argc != 4) { fprintf(stderr,"usage: %s plain|splice256|splice1m|null1m port bytes\n",argv[0]); return 1; }
	mode = argv[1];
	if (strcmp(mode,"plain") && strcmp(mode,"splice256") && strcmp(mode,"splice1m") && strcmp(mode,"null1m")) return 1;
	discard = !strcmp(mode,"null1m");
	total = strtoull(argv[3], NULL, 10);
	if (!total || total > 4ULL*1024*1024*1024) return 1;
	address.sin_port = htons((unsigned short)atoi(argv[2]));
	if (inet_pton(AF_INET, "192.168.7.4", &address.sin_addr) != 1) return 1;
	buffer = malloc(128*1024);
	if (!buffer) fail("malloc");
	file_fd = discard ? open("/dev/null",O_WRONLY) : mkstemp(file);
	if (file_fd < 0) fail("open output");
	if (!discard && unlink(file)) fail("unlink");
	if (strcmp(mode,"plain")) {
		int requested = strcmp(mode,"splice256") ? 1024*1024 : 256*1024;
		int actual;
		if (pipe2(pipes, O_CLOEXEC)) fail("pipe2");
		actual = fcntl(pipes[1], F_SETPIPE_SZ, requested);
		if (actual < 0) fail("F_SETPIPE_SZ");
		pipe_bytes = actual;
	}
	listen_fd = socket(AF_INET, SOCK_STREAM, 0);
	if (listen_fd < 0) fail("socket");
	if (setsockopt(listen_fd,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes))) fail("SO_REUSEADDR");
	if (bind(listen_fd,(struct sockaddr *)&address,sizeof(address))) fail("bind");
	if (listen(listen_fd,1)) fail("listen");
	fprintf(stderr,"READY mode=%s pipe_bytes=%zu\n",mode,pipe_bytes);
	alarm(120);
	sock = accept(listen_fd,NULL,NULL);
	if (sock < 0) fail("accept");
	alarm(0);
	close(listen_fd);
	if (setsockopt(sock,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout)) ||
	    setsockopt(sock,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout))) fail("timeout");
	start = now();
	while (received < total) {
		size_t want = total - received;
		ssize_t in;
		if (!strcmp(mode,"plain")) {
			if (want > 128*1024) want = 128*1024;
			in = read(sock,buffer,want);
		} else {
			if (want > pipe_bytes) want = pipe_bytes;
			in = splice(sock,NULL,pipes[1],NULL,want,SPLICE_F_MOVE|SPLICE_F_MORE);
		}
		in_calls++;
		if (in < 0 && errno == EINTR) continue;
		if (in <= 0) { if (!in) errno=ECONNRESET; fail("receive"); }
		if ((size_t)in > max_in) max_in = in;
		{
			size_t done = 0;
			while (done < (size_t)in) {
				ssize_t out;
				if (!strcmp(mode,"plain")) out = write(file_fd,buffer+done,in-done);
				else out = splice(pipes[0],NULL,file_fd,NULL,in-done,SPLICE_F_MOVE);
				out_calls++;
				if (out < 0 && errno == EINTR) continue;
				if (out <= 0) { if (!out) errno=EIO; fail("write"); }
				done += out;
			}
		}
		received += in;
	}
	elapsed = now()-start;
	snprintf(message,sizeof(message),"{\"stage\":\"received\",\"mode\":\"%s\",\"bytes\":%llu,\"seconds\":%.6f,\"MiB_s\":%.6f,\"pipe_bytes\":%zu,\"in_calls\":%llu,\"out_calls\":%llu,\"max_in\":%zu}\n",
		 mode,(unsigned long long)received,elapsed,received/1048576.0/elapsed,pipe_bytes,
		 (unsigned long long)in_calls,(unsigned long long)out_calls,max_in);
	send_all(sock,message,strlen(message));
	fputs(message,stdout); fflush(stdout);
	/* Client stops perf before allowing flush and hash verification. */
	{
		size_t have=0;
		while (have<sizeof(go)) {
			ssize_t n=read(sock,go+have,sizeof(go)-have);
			if (n<0 && errno==EINTR) continue;
			if (n<=0) fail("ack");
			have+=n;
		}
		if (memcmp(go,"GO\n",3)) { errno=EINVAL; fail("ack"); }
	}
	if (discard) {
		snprintf(message,sizeof(message),"{\"stage\":\"discarded\",\"bytes\":%llu,\"sha256\":null,\"flush_seconds\":null}\n",(unsigned long long)received);
		goto finish;
	}
	flush_start=now();
	if (fsync(file_fd)) fail("fsync");
	flush_seconds=now()-flush_start;
	{
		int result=posix_fadvise(file_fd,0,0,POSIX_FADV_DONTNEED);
		if (result) { errno=result; fail("posix_fadvise"); }
	}
	snprintf(command,sizeof(command),"sha256sum /proc/self/fd/%d",file_fd);
	hash=popen(command,"r");
	if (!hash) fail("popen sha256sum");
	if (fscanf(hash,"%64s",digest)!=1 || strlen(digest)!=64) { errno=EIO; fail("sha256sum output"); }
	if (pclose(hash)!=0) { errno=EIO; fail("sha256sum exit"); }
	snprintf(message,sizeof(message),"{\"stage\":\"verified\",\"sha256\":\"%s\",\"flush_seconds\":%.6f}\n",digest,flush_seconds);
finish:
	send_all(sock,message,strlen(message));
	fputs(message,stdout);
	close(sock); close(file_fd);
	if (pipes[0]>=0) {close(pipes[0]); close(pipes[1]);}
	free(buffer);
	return 0;
}
