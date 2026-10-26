/* Regression checks for framing after short writes and output failures. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

typedef ssize_t (*recvfile_fn)(int,int,off_t,size_t);
#define CHECK(x) do { if (!(x)) {fprintf(stderr,"FAIL line %d: %s (errno=%d)\n",__LINE__,#x,errno); exit(1);} } while (0)
static void send_data(int fd,const char *buffer,size_t size)
{
	while(size) {
		ssize_t n=write(fd,buffer,size);
		if(n<0 && errno==EINTR) continue;
		if(n<=0) _exit(2);
		buffer+=n; size-=n;
	}
}
static void run_case(recvfile_fn recvfile,int which)
{
	int sockets[2], fd, status;
	char path[]="/tmp/samba-splice-test-XXXXXX", marker[4];
	const size_t count=256*1024;
	char *data=malloc(count), *actual=malloc(count);
	size_t i;
	pid_t producer;
	ssize_t result;
	CHECK(data && actual);
	for(i=0;i<count;i++) data[i]=(char)(i*17+3);
	CHECK(socketpair(AF_UNIX,SOCK_STREAM,0,sockets)==0);
	fd=mkstemp(path); CHECK(fd>=0); CHECK(unlink(path)==0);
	CHECK(recvfile(-1,-1,0,0)==0);
	if(which==3) {
		CHECK(fcntl(sockets[0],F_SETFL,O_NONBLOCK)==0);
		errno=0;
		CHECK(recvfile(sockets[0],fd,0,count)==-1);
		CHECK(errno==EAGAIN || errno==EWOULDBLOCK);
		return;
	}
	producer=fork(); CHECK(producer>=0);
	if(!producer) {
		close(sockets[0]); close(fd);
		send_data(sockets[1],data,which==4 ? count/2 : count);
		if(which!=4) send_data(sockets[1],"NEXT",4);
		close(sockets[1]); _exit(0);
	}
	close(sockets[1]);
	if(which==1) {
		struct rlimit limit;
		CHECK(getrlimit(RLIMIT_FSIZE,&limit)==0);
		limit.rlim_cur=32768;
		CHECK(setrlimit(RLIMIT_FSIZE,&limit)==0);
		signal(SIGXFSZ,SIG_IGN);
	}
	if(which==2) {close(fd); fd=open("/dev/full",O_WRONLY); CHECK(fd>=0);}
	if(which==5) CHECK(fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_APPEND)==0);
	errno=0;
	result=recvfile(sockets[0],which==6 ? -1 : fd,which==0 ? 4096 : which==5 ? 123 : 0,count);
	if(which==0) CHECK(result==(ssize_t)count);
	if(which==1) {CHECK(result==32768); CHECK(errno==EFBIG);}
	if(which==2 || which==4) CHECK(result==-1);
	if(which==5) CHECK(result==(ssize_t)count);
	if(which==6) CHECK(result==0);
	if(which!=4) {
		size_t have=0;
		while(have<sizeof(marker)) {
			ssize_t n=read(sockets[0],marker+have,sizeof(marker)-have);
			CHECK(n>0); have+=n;
		}
		CHECK(memcmp(marker,"NEXT",4)==0);
	}
	CHECK(waitpid(producer,&status,0)==producer);
	CHECK(WIFEXITED(status) && WEXITSTATUS(status)==0);
	if(which==0 || which==1 || which==5) {
		CHECK(pread(fd,actual,result,which==0 ? 4096 : 0)==result);
		CHECK(memcmp(actual,data,result)==0);
	}
	close(fd); close(sockets[0]); free(data); free(actual);
}
int main(int argc,char **argv)
{
	const char *names[]={"normal-offset","partial-EFBIG-framing","first-output-error-framing","nonblocking-EAGAIN","EOF-after-progress","O_APPEND-fallback","drain-only-fallback"};
	void *library;
	recvfile_fn recvfile;
	int which, failed=0;
	if(argc<2 || argc>3) return 2;
	library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL); CHECK(library);
	recvfile=(recvfile_fn)dlvsym(library,"sys_recvfile","SMBCONF_0.0.1"); CHECK(recvfile);
	for(which=0;which<(argc==3 ? 7 : 5);which++) {
		pid_t worker=fork(); int status;
		CHECK(worker>=0);
		if(!worker) {alarm(15); run_case(recvfile,which); _exit(0);}
		CHECK(waitpid(worker,&status,0)==worker);
		if(!WIFEXITED(status) || WEXITSTATUS(status)) {
			printf("FAIL %s\n",names[which]); failed++;
		} else printf("PASS %s\n",names[which]);
		fflush(stdout);
	}
	dlclose(library);
	return failed ? 1 : 0;
}
