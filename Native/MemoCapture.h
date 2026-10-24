#ifndef MEMO_CAPTURE_H
#define MEMO_CAPTURE_H
#include <stdint.h>
#include <stddef.h>
typedef struct MemoCapture MemoCapture;
typedef struct {
    int64_t bytes;
    int64_t packets;
    int64_t media_microseconds;
    int phase; /* 0 ready, 1 opening, 2 probing, 3 writing, 4 finishing, 5 ended */
} MemoProgress;
MemoCapture *memo_capture_create(void);
void memo_capture_cancel(MemoCapture *capture);
/* Call only after the blocking capture/remux function has returned. */
void memo_capture_destroy(MemoCapture *capture);
MemoProgress memo_capture_progress(MemoCapture *capture);
/* Network URL only. Returns 0 on EOF or requested stop; negative FFmpeg error otherwise. */
int memo_capture_run(MemoCapture *capture, const char *url, const char *agent,
                     const char *referer, const char *cookie, const char *output);
/* Local files only. Input is always retained; caller publishes the output atomically. */
int memo_capture_mp4(MemoCapture *capture, const char *input, const char *output);
void memo_capture_error(int code, char *buffer, size_t length);
int memo_capture_retryable(int code);
const char *memo_capture_version(void);
#endif
