/* soak <seconds>: SCHED_IDLE busy loop, prints loop iterations per second.
 * Run once on an idle system for the baseline; the ratio under load = free CPU. */
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	struct sched_param sp = { 0 };
	double secs = argc > 1 ? atof(argv[1]) : 10, t0, t;
	unsigned long long n = 0;
	volatile unsigned int sink = 0;

	if (sched_setscheduler(0, SCHED_IDLE, &sp))
		perror("SCHED_IDLE");
	t0 = now();
	do {
		for (unsigned int i = 0; i < 100000; i++)
			sink += i;
		n++;
		t = now();
	} while (t - t0 < secs);
	printf("%.0f\n", n * 100000.0 / (t - t0));
	return 0;
}
