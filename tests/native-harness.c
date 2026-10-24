#include "MemoCapture.h"
#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
struct Cancellation { MemoCapture *capture; int milliseconds; };
static void *cancel_after(void *opaque) {
    struct Cancellation *c = opaque;
    if (c->milliseconds < 0) {
        for (int i = 0; i < 500; i++) {
            if (memo_capture_progress(c->capture).packets >= 5) break;
            usleep(10000);
        }
    } else usleep(c->milliseconds * 1000);
    memo_capture_cancel(c->capture); return NULL;
}
int main(int argc, char **argv) {
    if (argc < 4) return 2;
    MemoCapture *s = memo_capture_create(); if (!s) return 3;
    pthread_t thread;
    struct Cancellation c = {s, argc > 5 ? atoi(argv[5]) : 0};
    int has_cancel = c.milliseconds != 0;
    if (c.milliseconds == -2) { memo_capture_cancel(s); has_cancel = 0; }
    if (has_cancel) pthread_create(&thread, NULL, cancel_after, &c);
    int result = argv[1][0] == 'm' ? memo_capture_mp4(s, argv[2], argv[3]) :
        memo_capture_run(s, argv[2], "Memo-fixture", "", argc > 4 ? argv[4] : "", argv[3]);
    if (has_cancel) pthread_join(thread, NULL);
    MemoProgress p = memo_capture_progress(s);
    printf("{\"code\":%d,\"bytes\":%lld,\"packets\":%lld,\"media_us\":%lld}\n", result,
        (long long)p.bytes, (long long)p.packets, (long long)p.media_microseconds);
    memo_capture_destroy(s); return 0;
}
