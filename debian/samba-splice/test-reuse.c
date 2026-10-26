/* Reuse the same shim state across success, short writes, EOF and drain failures. */
#define _GNU_SOURCE
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

typedef ssize_t (*recvfile_fn)(int, int, off_t, size_t);
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL %d: %s errno=%d\n",__LINE__,#x,errno); exit(1); } } while (0)
static unsigned char data[1024*1024], actual[1024*1024];

static int fd_count(void)
{
	DIR *d=opendir("/proc/self/fd");
	struct dirent *e;
	int n=0;
	CHECK(d);
	while ((e=readdir(d))) if (strcmp(e->d_name,".") && strcmp(e->d_name,"..")) n++;
	closedir(d);
	return n;
}

static long rss_kb(void)
{
	FILE *f=fopen("/proc/self/statm","r");
	unsigned long size, rss;
	CHECK(f && fscanf(f,"%lu %lu",&size,&rss)==2);
	fclose(f);
	return (long)rss*(sysconf(_SC_PAGESIZE)/1024);
}

static void send_all(int fd,const void *p,size_t n)
{
	const char *s=p;
	while (n) {
		ssize_t done=write(fd,s,n);
		if (done<0 && errno==EINTR) continue;
		if (done<=0) _exit(2);
		s+=done; n-=(size_t)done;
	}
}

static void run(recvfile_fn fn,int mode,int iteration)
{
	int s[2], fd, status;
	char path[]="/tmp/samba-splice-reuse-XXXXXX", marker[4];
	size_t n=iteration%100==0 ? sizeof(data) : 65536+(size_t)(iteration%31);
	off_t offset=mode==0 ? (off_t)(iteration%33) : 0;
	struct rlimit old, limited;
	pid_t child;
	ssize_t result;
	CHECK(socketpair(AF_UNIX,SOCK_STREAM,0,s)==0);
	fd=mkstemp(path); CHECK(fd>=0 && unlink(path)==0);
	if (mode==4) {
		CHECK(fcntl(s[0],F_SETFL,O_NONBLOCK)==0);
		errno=0;
		CHECK(fn(s[0],fd,0,n)==-1 && (errno==EAGAIN || errno==EWOULDBLOCK));
		close(fd); close(s[0]); close(s[1]); return;
	}
	child=fork(); CHECK(child>=0);
	if (!child) {
		close(s[0]); close(fd);
		send_all(s[1],data,(mode==3 || mode==5) ? n/2 : n);
		if (mode!=3 && mode!=5) send_all(s[1],"NEXT",4);
		close(s[1]); _exit(0);
	}
	close(s[1]);
	if (mode==1) {
		CHECK(getrlimit(RLIMIT_FSIZE,&old)==0);
		limited=old; limited.rlim_cur=32768;
		CHECK(setrlimit(RLIMIT_FSIZE,&limited)==0);
	}
	if (mode==2 || mode==5) { close(fd); fd=open("/dev/full",O_WRONLY); CHECK(fd>=0); }
	errno=0;
	result=fn(s[0],fd,offset,n);
	if (mode==1) CHECK(setrlimit(RLIMIT_FSIZE,&old)==0);
	if (mode==0) CHECK(result==(ssize_t)n);
	if (mode==1) CHECK(result==32768);
	if (mode==2 || mode==3 || mode==5) CHECK(result==-1);
	if (mode!=3 && mode!=5) {
		size_t got=0;
		while (got<4) { ssize_t m=read(s[0],marker+got,4-got); CHECK(m>0); got+=(size_t)m; }
		CHECK(memcmp(marker,"NEXT",4)==0);
	}
	CHECK(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
	if (mode==0 || mode==1 || mode==3) {
		size_t copied=mode==0 ? n : mode==1 ? 32768 : n/2;
		CHECK(pread(fd,actual,copied,offset)==(ssize_t)copied);
		CHECK(memcmp(data,actual,copied)==0);
	}
	close(fd); close(s[0]);
}

int main(int argc,char **argv)
{
	void *lib;
	recvfile_fn fn;
	int i, base, maxfd=0;
	long warm, maxrss=0;
	CHECK(argc==2);
	alarm(300); signal(SIGXFSZ,SIG_IGN);
	for (i=0;i<(int)sizeof(data);i++) data[i]=(unsigned char)(i*17+3);
	memset(actual,0,sizeof(actual));
	lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); CHECK(lib);
	fn=(recvfile_fn)dlvsym(lib,"sys_recvfile","SMBCONF_0.0.1"); CHECK(fn);
	base=fd_count();
	for (i=0;i<60;i++) run(fn,i%6,i);
	warm=rss_kb();
	printf("{\"warm_rss_kb\":%ld,\"base_fds\":%d,\"samples\":[",warm,base);
	for (i=0;i<1800;i++) {
		int n;
		long rss;
		run(fn,i%6,i);
		n=fd_count(); CHECK(n==base || n==base+2);
		if (n>maxfd) maxfd=n;
		if ((i+1)%60) continue;
		rss=rss_kb(); if (rss>maxrss) maxrss=rss;
		printf("%s{\"iteration\":%d,\"fds\":%d,\"rss_kb\":%ld}",i==59 ? "" : ",",i+1,n,rss);
		fflush(stdout);
	}
	/* A final successful call must work after the last drain-failure reset. */
	run(fn,0,1); CHECK(fd_count()==base+2);
	printf("],\"iterations\":1800,\"max_fds\":%d,\"final_fds\":%d,\"final_rss_kb\":%ld,\"max_rss_kb\":%ld,\"passed\":true}\n",maxfd,fd_count(),rss_kb(),maxrss);
	return 0;
}
