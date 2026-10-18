/*
 * phase88-jack-io.c - minimal JACK client: play a sine, or record ports.
 *
 *   phase88-jack-io --sine <port> [<port> ...]
 *       owns output ports, connects them to the listed ports and feeds a
 *       997 Hz tone at -6 dBFS until killed (Ctrl-C).
 *   phase88-jack-io --record <seconds> <port> [<port> ...]
 *       records those ports and prints the per-channel peak and rms in dBFS
 *       over the last 60 % of the take (the start of a take often carries the
 *       click of connecting or of a relay in the PHASE 88 input stage).
 *
 * Built because the stock clients are awkward here: jack_rec is transport
 * driven and waits for a rolling transport jackd does not start by itself, and
 * jack_metro needs --bpm and prints its usage on a stray option.
 *
 *   cc -O2 -Wall -o phase88-jack-io phase88-jack-io.c -ljack
 *   (needs libjack-jackd2-dev for <jack/jack.h>)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <math.h>

#include <jack/jack.h>

#define MAXP 32

static jack_port_t *mine[MAXP];		/* this client's own ports */
static const char *want_name[MAXP];	/* ports asked for on the command line */
static int nports;
static int mode_rec;
static double sr = 48000.0;
static float *buf[MAXP];
static long frames_want;
static volatile long frames_got;
static volatile int done;

static int process(jack_nframes_t n, void *arg)
{
	static double ph;
	jack_nframes_t i;
	int k;

	(void)arg;
	for (k = 0; k < nports; k++) {
		float *b = jack_port_get_buffer(mine[k], n);

		if (!b)
			continue;
		if (mode_rec) {
			if (frames_got >= frames_want)
				continue;
			for (i = 0; i < n && frames_got + (long)i < frames_want; i++)
				buf[k][frames_got + i] = b[i];
		} else {
			for (i = 0; i < n; i++) {
				ph += 2.0 * 3.14159265358979 * 997.0 / sr;
				b[i] = 0.5f * sinf((float)ph);
			}
		}
	}
	if (mode_rec)
		frames_got += n;
	return 0;
}

static void bye(void *arg)
{
	(void)arg;
	fprintf(stderr, "phase88-jack-io: the jack server went away\n");
	exit(2);
}

static void stop(int sig)
{
	(void)sig;
	done = 1;
}

static double dbfs(double v)
{
	return v <= 0.0 ? -999.0 : 20.0 * log10(v);
}

int main(int argc, char **argv)
{
	jack_client_t *c;
	int i, rc = 0;
	double secs = 3.0;
	long skip, j;
	int verbose = 0;

	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);
	verbose = getenv("PHASE88_VERBOSE") != NULL;

	if (argc < 3) {
		fprintf(stderr,
			"usage: phase88-jack-io --sine <port> [<port> ...]\n"
			"       phase88-jack-io --record <sec> <port> [<port> ...]\n");
		return 1;
	}
	if (!strcmp(argv[1], "--record")) {
		mode_rec = 1;
		secs = atof(argv[2]);
	} else if (strcmp(argv[1], "--sine")) {
		fprintf(stderr, "phase88-jack-io: unknown mode %s\n", argv[1]);
		return 1;
	}
	for (i = mode_rec ? 3 : 2; i < argc; i++) {
		if (nports == MAXP) {
			fprintf(stderr, "phase88-jack-io: only %d ports\n", MAXP);
			break;
		}
		want_name[nports++] = argv[i];
	}

	c = jack_client_open(mode_rec ? "phase88-rec" : "phase88-tone", 0, NULL);
	if (!c) {
		fprintf(stderr, "phase88-jack-io: no jack server running?\n");
		return 1;
	}
	sr = jack_get_sample_rate(c);

	for (i = 0; i < nports; i++) {
		char shortname[16];
		unsigned long flags;

		snprintf(shortname, sizeof(shortname), mode_rec ? "in%d" : "out%d",
			 i + 1);
		flags = mode_rec ? JackPortIsInput : JackPortIsOutput;
		mine[i] = jack_port_register(c, shortname,
					     JACK_DEFAULT_AUDIO_TYPE, flags, 0);
		if (!mine[i]) {
			fprintf(stderr, "phase88-jack-io: cannot register %s\n",
				shortname);
			return 1;
		}
		if (mode_rec && !jack_port_by_name(c, want_name[i])) {
			fprintf(stderr, "phase88-jack-io: no such port: %s\n",
				want_name[i]);
			rc = 1;
			goto out;
		}
	}
	jack_set_process_callback(c, process, NULL);
	jack_on_shutdown(c, bye, NULL);
	if (jack_activate(c)) {
		fprintf(stderr, "phase88-jack-io: cannot activate client\n");
		rc = 1;
		goto out;
	}

	/*
	 * Connect only after jack_activate(): with jackdmp 1.9.22 a
	 * jack_connect() from a client that is not active yet fails (the engine
	 * refuses the graph change), and the same call made later from the
	 * command line tool works.  That is the one thing here that is not
	 * obvious from the API documentation.
	 */
	for (i = 0; i < nports; i++) {
		const char *src = mode_rec ? want_name[i] : jack_port_name(mine[i]);
		const char *dst = mode_rec ? jack_port_name(mine[i]) : want_name[i];

		if (verbose)
			fprintf(stderr, "phase88-jack-io: %s -> %s\n", src, dst);
		if (jack_connect(c, src, dst)) {
			fprintf(stderr, "phase88-jack-io: cannot connect %s -> %s\n",
				src, dst);
			rc = 1;
			goto out;
		}
	}

	if (!mode_rec) {
		signal(SIGINT, stop);
		signal(SIGTERM, stop);
		printf("phase88-jack-io: 997 Hz at -6 dBFS into %d port(s)\n",
		       nports);
		fflush(stdout);
		while (!done)
			sleep(1);
		goto out;
	}

	frames_want = (long)(secs * sr);
	for (i = 0; i < nports; i++)
		buf[i] = calloc(frames_want + (long)sr, sizeof(float));
	frames_got = 0;
	printf("phase88-jack-io: client active, waiting for %ld frames\n",
	       frames_want);
	while (frames_got < frames_want && !done) {
		usleep(500000);
		printf("  ... %ld frames\n", frames_got);
	}
	if (frames_got < frames_want)
		printf("phase88-jack-io: only %ld of %ld frames arrived\n",
		       frames_got, frames_want);

	skip = frames_want * 2 / 5;
	if (skip >= frames_got)
		skip = 0;
	printf("phase88-jack-io: %.1f s of %d channel(s), level over the last "
	       "%.1f s:\n", frames_got / sr, nports, (frames_got - skip) / sr);
	for (i = 0; i < nports; i++) {
		double peak = 0.0, sum = 0.0, n = 0.0;

		for (j = skip; j < frames_got; j++) {
			double v = fabs(buf[i][j]);

			if (v > peak)
				peak = v;
			sum += v * v;
			n += 1.0;
		}
		printf("  %-24s peak %8.1f dBFS   rms %8.1f dBFS\n",
		       want_name[i], dbfs(peak),
		       n > 0 ? dbfs(sqrt(sum / n)) : -999.0);
	}
out:
	jack_client_close(c);
	return rc;
}
