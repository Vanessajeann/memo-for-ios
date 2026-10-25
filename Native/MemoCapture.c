#include "MemoCapture.h"
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/time.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/avstring.h>
#include <stdatomic.h>
#include <pthread.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

struct MemoCapture {
    atomic_int cancelled;
    atomic_int phase;
    atomic_int_fast64_t bytes, packets, media_us, last_progress;
    int timed_out;
};
static pthread_once_t initialized = PTHREAD_ONCE_INIT;
static void initialize(void) {
    avformat_network_init();
    /* FFmpeg logs may contain signed URLs and headers; expose only sanitized error codes. */
#ifdef MEMO_NATIVE_TEST
    av_log_set_level(AV_LOG_WARNING);
#else
    av_log_set_level(AV_LOG_QUIET);
#endif
}
MemoCapture *memo_capture_create(void) {
    pthread_once(&initialized, initialize);
    MemoCapture *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    atomic_init(&s->cancelled, 0); atomic_init(&s->phase, 0);
    atomic_init(&s->bytes, 0); atomic_init(&s->packets, 0);
    atomic_init(&s->media_us, 0); atomic_init(&s->last_progress, av_gettime_relative());
    return s;
}
void memo_capture_cancel(MemoCapture *s) { if (s) atomic_store(&s->cancelled, 1); }
void memo_capture_destroy(MemoCapture *s) { free(s); }
MemoProgress memo_capture_progress(MemoCapture *s) {
    MemoProgress p = {0}; if (!s) return p;
    p.bytes = atomic_load(&s->bytes); p.packets = atomic_load(&s->packets);
    p.media_microseconds = atomic_load(&s->media_us); p.phase = atomic_load(&s->phase);
    return p;
}
static int interrupted(void *opaque) {
    MemoCapture *s = opaque;
    if (atomic_load(&s->cancelled)) return 1;
    int64_t limit = atomic_load(&s->phase) < 3 ? 20000000 : 60000000;
    if (av_gettime_relative() - atomic_load(&s->last_progress) > limit) {
        s->timed_out = 1; return 1;
    }
    return 0;
}
static int safe_header(const char *s) { return s && !strchr(s, '\r') && !strchr(s, '\n'); }

/* Use FFmpeg's domain/path scoped cookie store instead of a raw Cookie header,
 * so HTTP redirects and HLS CDN requests do not forward credentials to other hosts. */
static int add_cookies(AVDictionary **options, const char *url, const char *cookie) {
    if (!*cookie) return 0;
    char host[1024]; av_url_split(NULL, 0, NULL, 0, host, sizeof(host), NULL, NULL, 0, url);
    if (!*host) return AVERROR(EINVAL);
    size_t cap = strlen(cookie) + (strlen(host) + 24) * (strlen(cookie) / 2 + 1) + 1;
    if (cap > 2000000) return AVERROR(EINVAL);
    char *copy = av_strdup(cookie), *result = av_mallocz(cap);
    if (!copy || !result) { av_free(copy); av_free(result); return AVERROR(ENOMEM); }
    char *save = NULL; size_t used = 0;
    for (char *token = strtok_r(copy, ";", &save); token; token = strtok_r(NULL, ";", &save)) {
        while (*token == ' ' || *token == '\t') token++;
        if (!strchr(token, '=')) continue;
        int n = snprintf(result + used, cap - used, "%s; path=/; domain=%s%s\n", token, host,
                         av_strstart(url, "https://", NULL) ? "; secure=1" : "");
        if (n < 0 || (size_t)n >= cap - used) { av_free(copy); av_free(result); return AVERROR(EINVAL); }
        used += n;
    }
    int ret = av_dict_set(options, "cookies", result, 0);
    av_free(copy); av_free(result); return ret;
}

static int transfer(MemoCapture *s, const char *url, const char *agent,
                    const char *referer, const char *cookie, const char *output, int mp4) {
    if (!s || !url || !output) return AVERROR(EINVAL);
    if (!mp4 && !(av_strstart(url, "http://", NULL) || av_strstart(url, "https://", NULL) ||
        av_strstart(url, "rtmp://", NULL) || av_strstart(url, "rtmps://", NULL) || av_strstart(url, "rtsp://", NULL))) return AVERROR(EINVAL);
    if (!safe_header(agent) || !safe_header(referer) || !safe_header(cookie)) return AVERROR(EINVAL);
    AVFormatContext *in = NULL, *out = NULL; AVPacket *packet = NULL;
    AVDictionary *options = NULL, *mux_options = NULL;
    int *mapping = NULL, ret = 0, header_written = 0, trailer_ret = 0;
    int video = -1, audio = -1, started = mp4;
    int64_t origin_us = AV_NOPTS_VALUE;
    in = avformat_alloc_context();
    if (!in) return AVERROR(ENOMEM);
    in->interrupt_callback = (AVIOInterruptCB){interrupted, s};
    in->flags |= AVFMT_FLAG_GENPTS;
    av_dict_set(&options, "protocol_whitelist", mp4 ? "file" : "http,https,tcp,tls,crypto,rtmp,rtmps,rtmpt,rtmpts,rtsp,rtp,udp", 0);
    av_dict_set(&options, "rw_timeout", "20000000", 0);
    av_dict_set(&options, "tls_verify", "1", 0);
    if (av_strstart(url, "http", NULL)) {
        av_dict_set(&options, "user_agent", agent, 0);
        if (*referer) av_dict_set(&options, "referer", referer, 0);
        ret = add_cookies(&options, url, cookie); if (ret < 0) goto done;
    }
    if (av_strstart(url, "rtsp://", NULL)) av_dict_set(&options, "rtsp_transport", "tcp", 0);
    atomic_store(&s->phase, 1);
    ret = avformat_open_input(&in, url, NULL, &options); if (ret < 0) goto done;
    atomic_store(&s->phase, 2);
    ret = avformat_find_stream_info(in, NULL); if (ret < 0) goto done;
    video = av_find_best_stream(in, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    audio = av_find_best_stream(in, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (video < 0 && audio < 0) { ret = AVERROR_STREAM_NOT_FOUND; goto done; }
    if (video < 0) started = 1;
    ret = avformat_alloc_output_context2(&out, NULL, mp4 ? "mp4" : "matroska", output);
    if (ret < 0 || !out) { ret = ret < 0 ? ret : AVERROR(ENOMEM); goto done; }
    mapping = av_malloc_array(in->nb_streams, sizeof(*mapping));
    if (!mapping) { ret = AVERROR(ENOMEM); goto done; }
    for (unsigned i = 0; i < in->nb_streams; i++) {
        mapping[i] = -1;
        if ((int)i != video && (int)i != audio) continue;
        AVStream *stream = avformat_new_stream(out, NULL);
        if (!stream) { ret = AVERROR(ENOMEM); goto done; }
        mapping[i] = stream->index;
        ret = avcodec_parameters_copy(stream->codecpar, in->streams[i]->codecpar);
        if (ret < 0) goto done;
        stream->codecpar->codec_tag = 0;
        stream->time_base = in->streams[i]->time_base;
    }
    out->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_ZERO;
    out->max_interleave_delta = 1000000;
    out->flags |= AVFMT_FLAG_FLUSH_PACKETS | AVFMT_FLAG_AUTO_BSF;
    /* Fail rather than overwrite an unrelated recording. Callers allocate UUID paths. */
    int reserved = open(output, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (reserved < 0) { ret = AVERROR(errno); goto done; }
    close(reserved);
    ret = avio_open(&out->pb, output, AVIO_FLAG_WRITE); if (ret < 0) goto done;
    if (mp4) av_dict_set(&mux_options, "movflags", "+faststart", 0);
    else {
        av_dict_set(&mux_options, "cluster_time_limit", "1000", 0);
        av_dict_set(&mux_options, "flush_packets", "1", 0);
    }
    ret = avformat_write_header(out, &mux_options); if (ret < 0) goto done;
    header_written = 1;
    packet = av_packet_alloc(); if (!packet) { ret = AVERROR(ENOMEM); goto done; }
    atomic_store(&s->phase, 3); atomic_store(&s->last_progress, av_gettime_relative());
    while (!atomic_load(&s->cancelled)) {
        ret = av_read_frame(in, packet);
        if (ret < 0) break;
        int index = packet->stream_index;
        if (index < 0 || (unsigned)index >= in->nb_streams || mapping[index] < 0) { av_packet_unref(packet); continue; }
        if (!started) {
            if (index != video || !(packet->flags & AV_PKT_FLAG_KEY)) { av_packet_unref(packet); continue; }
            started = 1;
        }
        AVStream *src = in->streams[index], *dst = out->streams[mapping[index]];
        int size = packet->size;
        int64_t timestamp = packet->dts != AV_NOPTS_VALUE ? packet->dts : packet->pts;
        if (origin_us == AV_NOPTS_VALUE && timestamp != AV_NOPTS_VALUE) origin_us = av_rescale_q(timestamp, src->time_base, AV_TIME_BASE_Q);
        if (origin_us != AV_NOPTS_VALUE) {
            int64_t offset = av_rescale_q(origin_us, AV_TIME_BASE_Q, src->time_base);
            if (packet->pts != AV_NOPTS_VALUE) packet->pts -= offset;
            if (packet->dts != AV_NOPTS_VALUE) packet->dts -= offset;
        }
        int64_t media = packet->pts == AV_NOPTS_VALUE ? 0 : av_rescale_q(packet->pts + packet->duration, src->time_base, AV_TIME_BASE_Q);
        av_packet_rescale_ts(packet, src->time_base, dst->time_base);
        packet->stream_index = mapping[index]; packet->pos = -1;
        ret = av_interleaved_write_frame(out, packet);
        av_packet_unref(packet);
        if (ret < 0) break;
        avio_flush(out->pb);
        atomic_fetch_add(&s->bytes, size); atomic_fetch_add(&s->packets, 1);
        if (media > atomic_load(&s->media_us)) atomic_store(&s->media_us, media);
        atomic_store(&s->last_progress, av_gettime_relative());
    }
done:
    atomic_store(&s->phase, 4);
    if (header_written) trailer_ret = av_write_trailer(out);
    if (packet) av_packet_free(&packet);
    if (in) avformat_close_input(&in);
    if (out && out->pb) { int close_ret = avio_closep(&out->pb); if (trailer_ret >= 0 && close_ret < 0) trailer_ret = close_ret; }
    avformat_free_context(out); av_free(mapping);
    av_dict_free(&options); av_dict_free(&mux_options);
    if (s->timed_out) ret = AVERROR(ETIMEDOUT);
    else if (atomic_load(&s->cancelled)) ret = mp4 ? AVERROR_EXIT : 0;
    else if (ret == AVERROR_EOF) ret = 0;
    if (ret >= 0 && trailer_ret < 0) ret = trailer_ret;
    if (ret >= 0 && !atomic_load(&s->packets)) ret = AVERROR_INVALIDDATA;
    atomic_store(&s->phase, 5); return ret;
}
int memo_capture_run(MemoCapture *s, const char *url, const char *agent, const char *referer, const char *cookie, const char *output) {
    return transfer(s, url, agent, referer, cookie, output, 0);
}
int memo_capture_mp4(MemoCapture *s, const char *input, const char *output) {
    return transfer(s, input, "", "", "", output, 1);
}
/* HLS AVURLAsset may expose an empty static tracks array even when its segments
 * contain audio. Inspect the real demuxed stream instead of treating it as mute.
 * Run on a worker, with the same bounded/cancellable I/O and credential scoping
 * as capture. No decoded samples, output files or synthetic audio are produced. */
int memo_capture_probe_audio(MemoCapture *s, const char *url, const char *agent,
                             const char *referer, const char *cookie) {
    if (!s || !url || !(av_strstart(url,"http://",NULL) || av_strstart(url,"https://",NULL)) ||
        !safe_header(agent) || !safe_header(referer) || !safe_header(cookie)) return AVERROR(EINVAL);
    AVFormatContext *in = avformat_alloc_context();
    if (!in) return AVERROR(ENOMEM);
    AVPacket *packet = NULL;
    AVDictionary *options = NULL;
    int ret = 0;
    in->interrupt_callback = (AVIOInterruptCB){interrupted,s};
    atomic_store(&s->phase,1);
    av_dict_set(&options,"protocol_whitelist","http,https,tcp,tls,crypto",0);
    av_dict_set(&options,"rw_timeout","20000000",0);
    av_dict_set(&options,"tls_verify","1",0);
    av_dict_set(&options,"user_agent",agent,0);
    if (*referer) av_dict_set(&options,"referer",referer,0);
    ret = add_cookies(&options,url,cookie); if (ret < 0) goto finish_probe;
    ret = avformat_open_input(&in,url,NULL,&options); if (ret < 0) goto finish_probe;
    atomic_store(&s->phase,2);
    ret = avformat_find_stream_info(in,NULL); if (ret < 0) goto finish_probe;
    int audio = av_find_best_stream(in,AVMEDIA_TYPE_AUDIO,-1,-1,NULL,0);
    if (audio < 0) {
        ret = av_find_best_stream(in,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0) >= 0 ? 0 : AVERROR_INVALIDDATA;
        goto finish_probe;
    }
    packet = av_packet_alloc(); if (!packet) { ret = AVERROR(ENOMEM); goto finish_probe; }
    while ((ret = av_read_frame(in,packet)) >= 0) {
        int found = packet->stream_index == audio && packet->size > 0;
        av_packet_unref(packet);
        if (found) { ret = 1; break; }
        if (interrupted(s)) { ret = AVERROR_EXIT; break; }
    }
finish_probe:
    av_packet_free(&packet); avformat_close_input(&in); av_dict_free(&options);
    if (atomic_load(&s->cancelled)) ret = AVERROR_EXIT;
    else if (s->timed_out) ret = AVERROR(ETIMEDOUT);
    atomic_store(&s->phase,5); return ret;
}
void memo_capture_error(int code, char *buffer, size_t length) { av_strerror(code, buffer, length); }
int memo_capture_retryable(int e) {
    return e == AVERROR(ETIMEDOUT) || e == AVERROR(EIO) || e == AVERROR(ECONNRESET) ||
        e == AVERROR(ECONNREFUSED) || e == AVERROR(ENETUNREACH) || e == AVERROR(EPIPE) ||
        e == AVERROR_HTTP_SERVER_ERROR;
}
const char *memo_capture_version(void) { return av_version_info(); }

/* Two local DASH tracks, explicit stream mapping, no decoder or encoder. */
int memo_capture_join(MemoCapture *s, const char *video_path, const char *audio_path, const char *output) {
    if (!s || !video_path || !audio_path || !output) return AVERROR(EINVAL);
    AVFormatContext *in[2] = {NULL, NULL}, *out = NULL;
    AVPacket *packet[2] = {NULL, NULL};
    int index[2] = {-1,-1}, have[2] = {0,0}, ended[2] = {0,0};
    int ret = 0, header = 0, trailer = 0;
    const char *paths[2] = {video_path,audio_path};
    atomic_store(&s->phase, 1);
    for (int i = 0; i < 2; i++) {
        AVDictionary *options = NULL;
        av_dict_set(&options, "protocol_whitelist", "file", 0);
        in[i] = avformat_alloc_context();
        if (!in[i]) { av_dict_free(&options); ret = AVERROR(ENOMEM); goto finish; }
        in[i]->interrupt_callback = (AVIOInterruptCB){interrupted,s};
        ret = avformat_open_input(&in[i], paths[i], NULL, &options);
        av_dict_free(&options); if (ret < 0) goto finish;
        ret = avformat_find_stream_info(in[i],NULL); if (ret < 0) goto finish;
        index[i] = av_find_best_stream(in[i], i == 0 ? AVMEDIA_TYPE_VIDEO : AVMEDIA_TYPE_AUDIO, -1,-1,NULL,0);
        if (index[i] < 0) { ret = index[i]; goto finish; }
        packet[i] = av_packet_alloc(); if (!packet[i]) { ret = AVERROR(ENOMEM); goto finish; }
    }
    ret = avformat_alloc_output_context2(&out,NULL,"mp4",output); if (ret < 0 || !out) { ret = AVERROR(ENOMEM); goto finish; }
    for (int i = 0; i < 2; i++) {
        AVStream *dst = avformat_new_stream(out,NULL);
        if (!dst) { ret = AVERROR(ENOMEM); goto finish; }
        ret = avcodec_parameters_copy(dst->codecpar,in[i]->streams[index[i]]->codecpar); if (ret < 0) goto finish;
        dst->codecpar->codec_tag = 0; dst->time_base = in[i]->streams[index[i]]->time_base;
    }
    out->avoid_negative_ts = AVFMT_AVOID_NEG_TS_MAKE_ZERO;
    out->flags |= AVFMT_FLAG_AUTO_BSF;
    int reserved = open(output,O_WRONLY | O_CREAT | O_EXCL,0600);
    if (reserved < 0) { ret = AVERROR(errno); goto finish; } close(reserved);
    ret = avio_open(&out->pb,output,AVIO_FLAG_WRITE); if (ret < 0) goto finish;
    AVDictionary *mux = NULL; av_dict_set(&mux,"movflags","+faststart",0);
    ret = avformat_write_header(out,&mux); av_dict_free(&mux); if (ret < 0) goto finish;
    header = 1; atomic_store(&s->phase,3);
    while (!atomic_load(&s->cancelled)) {
        for (int i = 0; i < 2; i++) {
            while (!have[i] && !ended[i]) {
                ret = av_read_frame(in[i],packet[i]);
                if (ret == AVERROR_EOF) { ended[i] = 1; ret = 0; break; }
                if (ret < 0) goto finish;
                if (packet[i]->stream_index != index[i]) { av_packet_unref(packet[i]); continue; }
                have[i] = 1;
            }
        }
        if (!have[0] && !have[1]) { ret = 0; break; }
        int use = !have[0] ? 1 : 0;
        if (have[0] && have[1]) {
            int64_t t0 = packet[0]->dts == AV_NOPTS_VALUE ? packet[0]->pts : packet[0]->dts;
            int64_t t1 = packet[1]->dts == AV_NOPTS_VALUE ? packet[1]->pts : packet[1]->dts;
            use = av_compare_ts(t0,in[0]->streams[index[0]]->time_base,t1,in[1]->streams[index[1]]->time_base) > 0;
        }
        AVPacket *p = packet[use]; AVStream *src = in[use]->streams[index[use]], *dst = out->streams[use];
        int size = p->size;
        av_packet_rescale_ts(p,src->time_base,dst->time_base); p->stream_index = use; p->pos = -1;
        ret = av_interleaved_write_frame(out,p); av_packet_unref(p); have[use] = 0;
        if (ret < 0) goto finish;
        atomic_fetch_add(&s->bytes,size); atomic_fetch_add(&s->packets,1);
        atomic_store(&s->last_progress,av_gettime_relative());
    }
finish:
    atomic_store(&s->phase,4);
    if (header) trailer = av_write_trailer(out);
    for (int i = 0; i < 2; i++) { av_packet_free(&packet[i]); avformat_close_input(&in[i]); }
    if (out && out->pb) { int close_ret = avio_closep(&out->pb); if (trailer >= 0 && close_ret < 0) trailer = close_ret; }
    avformat_free_context(out);
    if (atomic_load(&s->cancelled)) ret = AVERROR_EXIT;
    else if (s->timed_out) ret = AVERROR(ETIMEDOUT);
    if (ret >= 0 && trailer < 0) ret = trailer;
    if (ret >= 0 && !atomic_load(&s->packets)) ret = AVERROR_INVALIDDATA;
    atomic_store(&s->phase,5); return ret;
}
