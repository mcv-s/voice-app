#ifndef VOICE_NOTES_LLM_H
#define VOICE_NOTES_LLM_H
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct VoiceNotesModel VoiceNotesModel;
typedef bool (*VoiceNotesCancelled)(void);
VoiceNotesModel *VoiceNotesCreate(const char *path);
void VoiceNotesDestroy(VoiceNotesModel *model);
char *VoiceNotesComplete(VoiceNotesModel *model, const char *prompt, int max_tokens, VoiceNotesCancelled cancelled);
void VoiceNotesFreeString(char *text);
#ifdef __cplusplus
}
#endif
#endif
