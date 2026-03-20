#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SP_INVALID_ID = -1,
    SP_TRANSPORT_UDP = 1,
    SP_TRANSPORT_TCP = 2,
    SP_CALL_STATE_DISCONNECTED = 0,
    SP_CALL_STATE_CONNECTING = 1,
    SP_CALL_STATE_INCOMING = 2,
    SP_CALL_STATE_EARLY = 3,
    SP_CALL_STATE_CONFIRMED = 4,
    SP_MEDIA_STATUS_NONE = 0,
    SP_MEDIA_STATUS_ACTIVE = 1,
    SP_MEDIA_STATUS_LOCAL_HOLD = 2,
    SP_MEDIA_STATUS_REMOTE_HOLD = 3
};

typedef void (*sp_incoming_call_cb)(int32_t acc_id, int32_t call_id);
typedef void (*sp_call_state_cb)(int32_t call_id);
typedef void (*sp_call_media_state_cb)(int32_t call_id);
typedef void (*sp_registration_state_cb)(int32_t acc_id);
typedef void (*sp_buddy_state_cb)(int32_t buddy_id);

typedef struct sp_callbacks {
    sp_incoming_call_cb on_incoming_call;
    sp_call_state_cb on_call_state;
    sp_call_media_state_cb on_call_media_state;
    sp_registration_state_cb on_registration_state;
    sp_buddy_state_cb on_buddy_state;
} sp_callbacks;

typedef struct sp_account_info {
    int32_t status;
    char status_text[128];
} sp_account_info;

typedef struct sp_call_info {
    int32_t state;
    int32_t media_status;
    int32_t last_status;
    char remote_info[256];
    char last_status_text[128];
} sp_call_info;

typedef struct sp_audio_device_info {
    int32_t id;
    char name[128];
    char driver[64];
    uint32_t input_count;
    uint32_t output_count;
} sp_audio_device_info;

typedef struct sp_buddy_info {
    int32_t id;
    int32_t status;
    int32_t monitor_pres;
    int32_t sub_state;
    uint32_t sub_term_code;
    char uri[256];
    char status_text[128];
} sp_buddy_info;

void sipphone_pj_register_thread_if_needed(const char *name);
int32_t sp_pjsip_create(const sp_callbacks *callbacks);
int32_t sp_pjsip_start(void);
void sp_pjsip_destroy(void);
int32_t sp_pjsip_create_transport(int32_t type, uint16_t port, int32_t *transport_id);
int32_t sp_pjsip_add_local_account(int32_t transport_id, int32_t make_default, int32_t *account_id);
int32_t sp_pjsip_add_account(
    const char *identity,
    const char *registrar,
    const char *username,
    const char *password,
    int32_t transport_id,
    int32_t *account_id
);
int32_t sp_pjsip_delete_account(int32_t account_id);
int32_t sp_pjsip_set_registration(int32_t account_id, int32_t renew);
int32_t sp_pjsip_handle_ip_change(void);
int32_t sp_pjsip_get_account_info(int32_t account_id, sp_account_info *info);
int32_t sp_pjsip_make_call(int32_t account_id, const char *destination, int32_t *call_id);
int32_t sp_pjsip_answer(int32_t call_id, uint32_t code);
int32_t sp_pjsip_hangup(int32_t call_id, uint32_t code);
int32_t sp_pjsip_hold(int32_t call_id);
int32_t sp_pjsip_transfer_replaces(int32_t call_id, int32_t other_call_id);
int32_t sp_pjsip_conference_connect(int32_t first_call_id, int32_t second_call_id);
int32_t sp_pjsip_attach_audio(int32_t call_id);
int32_t sp_pjsip_set_microphone_muted(int32_t muted);
int32_t sp_pjsip_set_microphone_volume(float volume);
int32_t sp_pjsip_set_speaker_volume(int32_t call_id, float volume);
int32_t sp_pjsip_start_call_remote_recording(int32_t call_id, const char *path, int32_t *recorder_id);
int32_t sp_pjsip_start_call_local_recording(int32_t call_id, const char *path, int32_t *recorder_id);
int32_t sp_pjsip_stop_call_recording(int32_t call_id, int32_t recorder_id);
int32_t sp_pjsip_set_extra_capture_device(int32_t capture_id);
int32_t sp_pjsip_clear_extra_capture_device(void);
int32_t sp_pjsip_set_sound_devices_with_mode(int32_t capture_id, int32_t playback_id, uint32_t mode);
int32_t sp_pjsip_set_sound_devices(int32_t capture_id, int32_t playback_id);
int32_t sp_pjsip_get_sound_devices(int32_t *capture_id, int32_t *playback_id);
int32_t sp_pjsip_set_null_sound_device(void);
int32_t sp_pjsip_get_capture_signal_levels(uint32_t *tx_level, uint32_t *rx_level);
int32_t sp_pjsip_get_port_signal_levels(int32_t port_id, uint32_t *tx_level, uint32_t *rx_level);
int32_t sp_pjsip_get_call_signal_levels(int32_t call_id, uint32_t *tx_level, uint32_t *rx_level);
int32_t sp_pjsip_play_wav_file(const char *path, int32_t *player_id);
int32_t sp_pjsip_destroy_player(int32_t player_id);
int32_t sp_pjsip_get_call_info(int32_t call_id, sp_call_info *info);
uint32_t sp_pjsip_enum_audio_devices(sp_audio_device_info *info, uint32_t capacity);
int32_t sp_pjsip_status_text(int32_t status, char *buffer, uint32_t capacity);
int32_t sp_pjsip_add_buddy(const char *uri, int32_t account_id, int32_t *buddy_id);
int32_t sp_pjsip_delete_buddy(int32_t buddy_id);
int32_t sp_pjsip_get_buddy_info(int32_t buddy_id, sp_buddy_info *info);

#ifdef __cplusplus
}
#endif
