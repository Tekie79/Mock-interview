#ifndef AUDIO_BUFFER_SLOTS_H
#define AUDIO_BUFFER_SLOTS_H

#include <stddef.h>

typedef struct AudioBufferSlots AudioBufferSlots;

AudioBufferSlots *AudioBufferSlotsCreate(size_t count);
void AudioBufferSlotsDestroy(AudioBufferSlots *slots);

/* Returns -1 when all slots are occupied. Neither operation blocks. */
int AudioBufferSlotsAcquire(AudioBufferSlots *slots);
void AudioBufferSlotsRelease(AudioBufferSlots *slots, int index);

#endif
