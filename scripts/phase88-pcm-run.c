/*
 * phase88-pcm-run.c - run a capture stream on one or more cards with DMA
 * timestamps enabled, so that /proc/asound/cardN/pcm0c/sub0/status carries a
 * consistent (hw_ptr, tstamp) pair to measure the real bit clock with.
 *
 * ALSA leaves the timestamp mode off for plain arecord, which is why the
 * kernel prints tstamp 0.000000000 and no rate can be derived.  JACK enables
 * it, so a card already streaming under jackd does not need this helper.
 *
 * Built without <alsa/asoundlib.h> because that header is not installed here;
 * only the handful of symbols we need is declared by hand.
 *
 *   cc -O2 -o phase88-pcm-run phase88-pcm-run.c -lasound
 *   phase88-pcm-run <seconds> <card> [card ...]
 *
 * It records silence (discarded), prints nothing while running and reports
 * underruns/overruns at the end.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>

typedef struct _snd_pcm snd_pcm_t;
typedef struct snd_pcm_hw_params snd_pcm_hw_params_t;
typedef struct snd_pcm_sw_params snd_pcm_sw_params_t;
typedef unsigned long snd_pcm_uframes_t;
typedef long snd_pcm_sframes_t;

#define SND_PCM_STREAM_CAPTURE 1
#define SND_PCM_NONBLOCK 1
#define SND_PCM_ACCESS_RW_INTERLEAVED 3
#define SND_PCM_FORMAT_S32_LE 10
#define SND_PCM_TSTAMP_ENABLE 1

extern int snd_pcm_open(snd_pcm_t **pcm, const char *name, int stream, int mode);
extern const char *snd_strerror(int errnum);
extern int snd_pcm_hw_params_malloc(snd_pcm_hw_params_t **ptr);
extern void snd_pcm_hw_params_free(snd_pcm_hw_params_t *obj);
extern int snd_pcm_hw_params_any(snd_pcm_t *pcm, snd_pcm_hw_params_t *params);
extern int snd_pcm_hw_params_set_access(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, int val);
extern int snd_pcm_hw_params_set_format(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, int val);
extern int snd_pcm_hw_params_set_channels(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int val);
extern int snd_pcm_hw_params_set_rate_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int *val, int *dir);
extern int snd_pcm_hw_params_set_buffer_time_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int *val, int *dir);
extern int snd_pcm_hw_params_set_period_time_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int *val, int *dir);
extern int snd_pcm_hw_params(snd_pcm_t *pcm, snd_pcm_hw_params_t *params);
extern int snd_pcm_sw_params_malloc(snd_pcm_sw_params_t **ptr);
extern void snd_pcm_sw_params_free(snd_pcm_sw_params_t *obj);
extern int snd_pcm_sw_params_current(snd_pcm_t *pcm, snd_pcm_sw_params_t *params);
extern int snd_pcm_sw_params_set_tstamp_mode(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, unsigned int val);
extern int snd_pcm_sw_params(snd_pcm_t *pcm, snd_pcm_sw_params_t *params);
extern int snd_pcm_prepare(snd_pcm_t *pcm);
extern int snd_pcm_start(snd_pcm_t *pcm);
extern snd_pcm_sframes_t snd_pcm_readi(snd_pcm_t *pcm, void *buffer, snd_pcm_uframes_t size);
extern int snd_pcm_close(snd_pcm_t *pcm);

#define MAXC 4
#define CHUNK 2048

static snd_pcm_t *pcm[MAXC];
static char name[MAXC][32];
static long xruns[MAXC];
static int ncards;

int main(int argc, char **argv)
{
	struct timespec t0, t;
	int i, secs;
	unsigned int rate, buft, pert;
	static char buf[CHUNK * 12 * 4];

	if (argc < 3) {
		fprintf(stderr, "usage: %s <seconds> <card> [card ...]\n", argv[0]);
		return 2;
	}
	secs = atoi(argv[1]);
	if (secs < 1)
		secs = 1;
	if (argc - 2 > MAXC)
		argc = MAXC + 2;

	for (i = 2; i < argc; i++) {
		snd_pcm_hw_params_t *hw;
		snd_pcm_sw_params_t *sw;
		int err;

		snprintf(name[ncards], sizeof(name[ncards]), "hw:%s", argv[i]);
		err = snd_pcm_open(&pcm[ncards], name[ncards],
				   SND_PCM_STREAM_CAPTURE, SND_PCM_NONBLOCK);
		if (err < 0) {
			fprintf(stderr, "%s: open: %s\n", name[ncards], snd_strerror(err));
			continue;
		}
		snd_pcm_hw_params_malloc(&hw);
		snd_pcm_hw_params_any(pcm[ncards], hw);
		snd_pcm_hw_params_set_access(pcm[ncards], hw, SND_PCM_ACCESS_RW_INTERLEAVED);
		snd_pcm_hw_params_set_format(pcm[ncards], hw, SND_PCM_FORMAT_S32_LE);
		snd_pcm_hw_params_set_channels(pcm[ncards], hw, 12);
		rate = 48000;
		snd_pcm_hw_params_set_rate_near(pcm[ncards], hw, &rate, NULL);
		buft = 200000;	/* 200 ms buffer, 100 ms period: plenty of slack,
				 * the measurement does not care about latency */
		pert = 100000;
		snd_pcm_hw_params_set_buffer_time_near(pcm[ncards], hw, &buft, NULL);
		snd_pcm_hw_params_set_period_time_near(pcm[ncards], hw, &pert, NULL);
		err = snd_pcm_hw_params(pcm[ncards], hw);
		snd_pcm_hw_params_free(hw);
		if (err < 0) {
			fprintf(stderr, "%s: hw params: %s\n", name[ncards], snd_strerror(err));
			snd_pcm_close(pcm[ncards]);
			continue;
		}
		snd_pcm_sw_params_malloc(&sw);
		snd_pcm_sw_params_current(pcm[ncards], sw);
		snd_pcm_sw_params_set_tstamp_mode(pcm[ncards], sw, SND_PCM_TSTAMP_ENABLE);
		if (snd_pcm_sw_params(pcm[ncards], sw) < 0)
			fprintf(stderr, "%s: warning: timestamp mode refused\n",
				name[ncards]);
		snd_pcm_sw_params_free(sw);
		if (snd_pcm_start(pcm[ncards]) < 0)
			snd_pcm_prepare(pcm[ncards]);
		ncards++;
	}
	if (!ncards)
		return 1;

	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (;;) {
		int alive = 0;
		clock_gettime(CLOCK_MONOTONIC, &t);
		if ((t.tv_sec - t0.tv_sec) >= secs)
			break;
		for (i = 0; i < ncards; i++) {
			snd_pcm_sframes_t r;
			if (!pcm[i])
				continue;
			alive = 1;
			r = snd_pcm_readi(pcm[i], buf, CHUNK);
			if (r == -EPIPE || r == -ESTRPIPE) {
				xruns[i]++;
				snd_pcm_prepare(pcm[i]);
				snd_pcm_start(pcm[i]);
			}
		}
		if (!alive)
			break;
		usleep(2000);
	}
	for (i = 0; i < ncards; i++) {
		if (xruns[i])
			fprintf(stderr, "%s: %ld overruns (measurement is not usable)\n",
				name[ncards] , xruns[i]);
		if (pcm[i])
			snd_pcm_close(pcm[i]);
	}
	return 0;
}
