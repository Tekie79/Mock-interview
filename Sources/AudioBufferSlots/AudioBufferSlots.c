#include "AudioBufferSlots.h"
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>

struct AudioBufferSlots {
    int count;
    atomic_bool occupied[];
};

AudioBufferSlots *AudioBufferSlotsCreate(size_t count) {
    if (count == 0 || count > 128) {
        return NULL;
    }
    AudioBufferSlots *slots = malloc(sizeof(AudioBufferSlots) + count * sizeof(atomic_bool));
    if (slots == NULL) {
        return NULL;
    }
    slots->count = (int)count;
    for (int index = 0; index < slots->count; index++) {
        atomic_init(&slots->occupied[index], false);
        if (!atomic_is_lock_free(&slots->occupied[index])) {
            free(slots);
            return NULL;
        }
    }
    return slots;
}

void AudioBufferSlotsDestroy(AudioBufferSlots *slots) {
    free(slots);
}

int AudioBufferSlotsAcquire(AudioBufferSlots *slots) {
    for (int index = 0; index < slots->count; index++) {
        bool available = false;
        if (atomic_compare_exchange_strong_explicit(&slots->occupied[index], &available, true,
                                                    memory_order_acquire, memory_order_relaxed)) {
            return index;
        }
    }
    return -1;
}

void AudioBufferSlotsRelease(AudioBufferSlots *slots, int index) {
    atomic_store_explicit(&slots->occupied[index], false, memory_order_release);
}
