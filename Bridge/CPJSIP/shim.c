#define PJ_AUTOCONF 1
#include <CPJSIP/CPJSIP.h>
#include <pjsua-lib/pjsua.h>
#include <string.h>

static sp_callbacks g_callbacks;
static int g_initialized = 0;
static pjsua_ext_snd_dev *g_extra_capture_dev = NULL;

static pjsua_conf_port_id sp_capture_conf_port(void) {
    if (g_extra_capture_dev != NULL) {
        return pjsua_ext_snd_dev_get_conf_port(g_extra_capture_dev);
    }
    return 0;
}

static void sp_set_codec_priority(const char *codec_name, pj_uint8_t priority) {
    pj_str_t codec_id = pj_str((char *)codec_name);
    pjsua_codec_set_priority(&codec_id, priority);
}

static void sp_configure_codecs(void) {
    sp_set_codec_priority("*", PJMEDIA_CODEC_PRIO_DISABLED);
    sp_set_codec_priority("PCMA/8000", 255);
    sp_set_codec_priority("PCMU/8000", 254);
    sp_set_codec_priority("G722/8000", 253);
    sp_set_codec_priority("telephone-event/8000", 252);
}

static int32_t sp_map_call_state(pjsip_inv_state state) {
    switch (state) {
        case PJSIP_INV_STATE_CALLING:
            return SP_CALL_STATE_CONNECTING;
        case PJSIP_INV_STATE_INCOMING:
            return SP_CALL_STATE_INCOMING;
        case PJSIP_INV_STATE_EARLY:
        case PJSIP_INV_STATE_CONNECTING:
            return SP_CALL_STATE_EARLY;
        case PJSIP_INV_STATE_CONFIRMED:
            return SP_CALL_STATE_CONFIRMED;
        case PJSIP_INV_STATE_DISCONNECTED:
        default:
            return SP_CALL_STATE_DISCONNECTED;
    }
}

static int32_t sp_map_media_status(pjsua_call_media_status status) {
    switch (status) {
        case PJSUA_CALL_MEDIA_ACTIVE:
            return SP_MEDIA_STATUS_ACTIVE;
        case PJSUA_CALL_MEDIA_LOCAL_HOLD:
            return SP_MEDIA_STATUS_LOCAL_HOLD;
        case PJSUA_CALL_MEDIA_REMOTE_HOLD:
            return SP_MEDIA_STATUS_REMOTE_HOLD;
        default:
            return SP_MEDIA_STATUS_NONE;
    }
}

static void sp_copy_pj_str(char *buffer, size_t capacity, const pj_str_t *value) {
    size_t length = 0;
    if (capacity == 0) {
        return;
    }

    if (value != NULL && value->ptr != NULL && value->slen > 0) {
        length = (size_t)value->slen;
        if (length >= capacity) {
            length = capacity - 1;
        }
        memcpy(buffer, value->ptr, length);
    }
    buffer[length] = '\0';
}

static void sp_on_incoming_call(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data *rdata) {
    (void)rdata;
    if (g_callbacks.on_incoming_call != NULL) {
        g_callbacks.on_incoming_call((int32_t)acc_id, (int32_t)call_id);
    }
}

static void sp_on_call_state(pjsua_call_id call_id, pjsip_event *event) {
    (void)event;
    if (g_callbacks.on_call_state != NULL) {
        g_callbacks.on_call_state((int32_t)call_id);
    }
}

static void sp_on_call_media_state(pjsua_call_id call_id) {
    if (g_callbacks.on_call_media_state != NULL) {
        g_callbacks.on_call_media_state((int32_t)call_id);
    }
}

static void sp_on_reg_state2(pjsua_acc_id acc_id, pjsua_reg_info *info) {
    (void)info;
    if (g_callbacks.on_registration_state != NULL) {
        g_callbacks.on_registration_state((int32_t)acc_id);
    }
}

static void sp_on_buddy_state(pjsua_buddy_id buddy_id) {
    if (g_callbacks.on_buddy_state != NULL) {
        g_callbacks.on_buddy_state((int32_t)buddy_id);
    }
}

void sipphone_pj_register_thread_if_needed(const char *name) {
    static __thread pj_thread_desc thread_desc;
    static __thread pj_thread_t *thread = NULL;

    if (!pj_thread_is_registered()) {
        pj_thread_register(name != NULL ? name : "sipphone", thread_desc, &thread);
    }
}

int32_t sp_pjsip_create(const sp_callbacks *callbacks) {
    pjsua_config config;
    pjsua_logging_config log_config;
    pjsua_media_config media_config;
    pj_status_t status;

    sipphone_pj_register_thread_if_needed("sipphone");
    if (g_initialized) {
        return PJ_SUCCESS;
    }

    memset(&g_callbacks, 0, sizeof(g_callbacks));
    if (callbacks != NULL) {
        g_callbacks = *callbacks;
    }

    status = pjsua_create();
    if (status != PJ_SUCCESS) {
        return status;
    }

    pjsua_config_default(&config);
    pjsua_logging_config_default(&log_config);
    pjsua_media_config_default(&media_config);

    config.max_calls = 8;
    config.cb.on_incoming_call = sp_on_incoming_call;
    config.cb.on_call_state = sp_on_call_state;
    config.cb.on_call_media_state = sp_on_call_media_state;
    config.cb.on_reg_state2 = sp_on_reg_state2;
    config.cb.on_buddy_state = sp_on_buddy_state;

    log_config.console_level = 3;
    log_config.level = 5;
    log_config.msg_logging = PJ_TRUE;
    media_config.clock_rate = 16000;
    media_config.snd_clock_rate = 16000;
    media_config.ec_tail_len = 0;
    media_config.enable_ice = PJ_FALSE;
    media_config.snd_auto_close_time = 0;

    status = pjsua_init(&config, &log_config, &media_config);
    if (status == PJ_SUCCESS) {
        sp_configure_codecs();
        g_initialized = 1;
    }
    return status;
}

int32_t sp_pjsip_start(void) {
    sipphone_pj_register_thread_if_needed("sipphone");
    return pjsua_start();
}

void sp_pjsip_destroy(void) {
    sipphone_pj_register_thread_if_needed("sipphone");
    if (!g_initialized) {
        return;
    }

    if (g_extra_capture_dev != NULL) {
        pjsua_ext_snd_dev_destroy(g_extra_capture_dev);
        g_extra_capture_dev = NULL;
    }

    pjsua_destroy();
    g_initialized = 0;
    memset(&g_callbacks, 0, sizeof(g_callbacks));
}

int32_t sp_pjsip_create_transport(int32_t type, uint16_t port, int32_t *transport_id) {
    pjsua_transport_config config;
    pjsua_transport_id id = PJSUA_INVALID_ID;
    pjsip_transport_type_e transport_type = type == SP_TRANSPORT_TCP ? PJSIP_TRANSPORT_TCP : PJSIP_TRANSPORT_UDP;
    pj_status_t status;

    sipphone_pj_register_thread_if_needed("sipphone");
    pjsua_transport_config_default(&config);
    config.port = port;
    status = pjsua_transport_create(transport_type, &config, &id);
    if (transport_id != NULL) {
        *transport_id = (int32_t)id;
    }
    return status;
}

int32_t sp_pjsip_add_local_account(int32_t transport_id, int32_t make_default, int32_t *account_id) {
    pjsua_acc_id id = PJSUA_INVALID_ID;
    pj_status_t status;

    sipphone_pj_register_thread_if_needed("sipphone");
    status = pjsua_acc_add_local((pjsua_transport_id)transport_id, make_default ? PJ_TRUE : PJ_FALSE, &id);
    if (account_id != NULL) {
        *account_id = (int32_t)id;
    }
    return status;
}

int32_t sp_pjsip_add_account(
    const char *identity,
    const char *registrar,
    const char *username,
    const char *password,
    int32_t transport_id,
    int32_t *account_id
) {
    pjsua_acc_config config;
    pjsua_acc_id id = PJSUA_INVALID_ID;
    pj_status_t status;

    sipphone_pj_register_thread_if_needed("sipphone");
    pjsua_acc_config_default(&config);
    config.id = pj_str((char *)(identity != NULL ? identity : ""));
    config.reg_uri = pj_str((char *)(registrar != NULL ? registrar : ""));
    config.reg_timeout = 300;
    config.reg_retry_interval = 60;
    config.reg_delay_before_refresh = 30;
    config.allow_contact_rewrite = PJ_TRUE;
    config.contact_rewrite_method = PJSUA_CONTACT_REWRITE_METHOD;
    config.ka_interval = 15;
    config.cred_count = 1;
    config.cred_info[0].realm = pj_str("*");
    config.cred_info[0].scheme = pj_str("Digest");
    config.cred_info[0].username = pj_str((char *)(username != NULL ? username : ""));
    config.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    config.cred_info[0].data = pj_str((char *)(password != NULL ? password : ""));
    if (transport_id != SP_INVALID_ID) {
        config.transport_id = (pjsua_transport_id)transport_id;
    }

    status = pjsua_acc_add(&config, PJ_TRUE, &id);
    if (account_id != NULL) {
        *account_id = (int32_t)id;
    }
    return status;
}

int32_t sp_pjsip_delete_account(int32_t account_id) {
    sipphone_pj_register_thread_if_needed("sipphone");
    return pjsua_acc_del((pjsua_acc_id)account_id);
}

int32_t sp_pjsip_set_registration(int32_t account_id, int32_t renew) {
    sipphone_pj_register_thread_if_needed("sipphone");
    return pjsua_acc_set_registration((pjsua_acc_id)account_id, renew ? PJ_TRUE : PJ_FALSE);
}

int32_t sp_pjsip_handle_ip_change(void) {
    pjsua_ip_change_param change_param;

    sipphone_pj_register_thread_if_needed("sipphone");
    pjsua_ip_change_param_default(&change_param);
    return pjsua_handle_ip_change(&change_param);
}

int32_t sp_pjsip_get_account_info(int32_t account_id, sp_account_info *info) {
    pjsua_acc_info account_info;
    pj_status_t status;

    if (info == NULL) {
        return PJ_EINVAL;
    }

    sipphone_pj_register_thread_if_needed("sipphone");
    status = pjsua_acc_get_info((pjsua_acc_id)account_id, &account_info);
    if (status != PJ_SUCCESS) {
        return status;
    }

    memset(info, 0, sizeof(*info));
    info->status = (int32_t)account_info.status;
    sp_copy_pj_str(info->status_text, sizeof(info->status_text), &account_info.status_text);
    return PJ_SUCCESS;
}

int32_t sp_pjsip_make_call(int32_t account_id, const char *destination, int32_t *call_id) {
    pjsua_call_id id = PJSUA_INVALID_ID;
    pj_str_t destination_str;
    pjsua_call_setting call_setting;
    pj_status_t status;

    sipphone_pj_register_thread_if_needed("sipphone");
    destination_str = pj_str((char *)(destination != NULL ? destination : ""));
    pjsua_call_setting_default(&call_setting);
    call_setting.aud_cnt = 1;
    call_setting.vid_cnt = 0;
    call_setting.txt_cnt = 0;
    status = pjsua_call_make_call((pjsua_acc_id)account_id, &destination_str, &call_setting, NULL, NULL, &id);
    if (call_id != NULL) {
        *call_id = (int32_t)id;
    }
    return status;
}

int32_t sp_pjsip_answer(int32_t call_id, uint32_t code) {
    sipphone_pj_register_thread_if_needed("sipphone");
    return pjsua_call_answer((pjsua_call_id)call_id, code, NULL, NULL);
}

int32_t sp_pjsip_hangup(int32_t call_id, uint32_t code) {
    sipphone_pj_register_thread_if_needed("sipphone");
    return pjsua_call_hangup((pjsua_call_id)call_id, code, NULL, NULL);
}

int32_t sp_pjsip_hold(int32_t call_id) {
    sipphone_pj_register_thread_if_needed("sipphone");
    return pjsua_call_set_hold((pjsua_call_id)call_id, NULL);
}

int32_t sp_pjsip_transfer_replaces(int32_t call_id, int32_t other_call_id) {
    sipphone_pj_register_thread_if_needed("sipphone");
    return pjsua_call_xfer_replaces((pjsua_call_id)call_id, (pjsua_call_id)other_call_id, 0, NULL);
}

int32_t sp_pjsip_conference_connect(int32_t first_call_id, int32_t second_call_id) {
    pjsua_conf_port_id first_port;
    pjsua_conf_port_id second_port;
    pj_status_t status;

    sipphone_pj_register_thread_if_needed("sipphone");
    first_port = pjsua_call_get_conf_port((pjsua_call_id)first_call_id);
    second_port = pjsua_call_get_conf_port((pjsua_call_id)second_call_id);
    if (first_port == PJSUA_INVALID_ID || second_port == PJSUA_INVALID_ID) {
        return PJ_EINVAL;
    }

    status = pjsua_conf_connect(first_port, second_port);
    if (status != PJ_SUCCESS) {
        return status;
    }

    return pjsua_conf_connect(second_port, first_port);
}

int32_t sp_pjsip_attach_audio(int32_t call_id) {
    pjsua_conf_port_id slot;
    pjsua_conf_port_id capture_port;
    pj_status_t status;

    sipphone_pj_register_thread_if_needed("sipphone");
    slot = pjsua_call_get_conf_port((pjsua_call_id)call_id);
    if (slot == PJSUA_INVALID_ID) {
        return PJ_EINVAL;
    }
    capture_port = sp_capture_conf_port();

    status = pjsua_conf_connect(slot, 0);
    if (status != PJ_SUCCESS) {
        return status;
    }

    if (capture_port != 0) {
        pjsua_conf_disconnect(0, slot);
    }

    status = pjsua_conf_connect(capture_port, slot);
    if (status != PJ_SUCCESS) {
        return status;
    }

    /* Ensure the actual media ports are at nominal gain. */
    pjsua_conf_adjust_tx_level(0, 1.0f);
    pjsua_conf_adjust_rx_level(slot, 1.0f);
    pjsua_conf_adjust_tx_level(slot, 1.0f);
    pjsua_conf_adjust_rx_level(capture_port, 1.0f);
    return PJ_SUCCESS;
}

int32_t sp_pjsip_set_microphone_muted(int32_t muted) {
    pjsua_conf_port_id capture_port;

    sipphone_pj_register_thread_if_needed("sipphone");
    capture_port = sp_capture_conf_port();
    return pjsua_conf_adjust_rx_level(capture_port, muted ? 0.0f : 1.0f);
}

int32_t sp_pjsip_set_microphone_volume(float volume) {
    pjsua_conf_port_id capture_port;

    sipphone_pj_register_thread_if_needed("sipphone");
    capture_port = sp_capture_conf_port();
    return pjsua_conf_adjust_rx_level(capture_port, volume);
}

int32_t sp_pjsip_set_speaker_volume(int32_t call_id, float volume) {
    pjsua_conf_port_id slot;
    pj_status_t status;

    sipphone_pj_register_thread_if_needed("sipphone");
    slot = pjsua_call_get_conf_port((pjsua_call_id)call_id);
    if (slot == PJSUA_INVALID_ID) {
        return PJ_EINVAL;
    }

    status = pjsua_conf_adjust_rx_level(slot, volume);
    if (status != PJ_SUCCESS) {
        return status;
    }

    return pjsua_conf_adjust_tx_level(0, volume);
}

static int32_t sp_pjsip_start_port_recording(pjsua_conf_port_id source_port, const char *path, int32_t *recorder_id) {
    pjsua_recorder_id rec_id = PJSUA_INVALID_ID;
    pjsua_conf_port_id rec_port;
    pj_str_t file_path;
    pj_status_t status;

    if (source_port == PJSUA_INVALID_ID || path == NULL || recorder_id == NULL) {
        return PJ_EINVAL;
    }

    sipphone_pj_register_thread_if_needed("sipphone");
    file_path = pj_str((char *)path);
    status = pjsua_recorder_create(&file_path, 0, NULL, 0, 0, &rec_id);
    if (status != PJ_SUCCESS) {
        return status;
    }

    rec_port = pjsua_recorder_get_conf_port(rec_id);
    status = pjsua_conf_connect(source_port, rec_port);
    if (status != PJ_SUCCESS) {
        pjsua_recorder_destroy(rec_id);
        return status;
    }

    *recorder_id = (int32_t)rec_id;
    return PJ_SUCCESS;
}

int32_t sp_pjsip_start_call_remote_recording(int32_t call_id, const char *path, int32_t *recorder_id) {
    pjsua_call_info call_info;
    pjsua_conf_port_id call_slot = PJSUA_INVALID_ID;
    pj_status_t status;
    unsigned mi;

    if (path == NULL || recorder_id == NULL) {
        return PJ_EINVAL;
    }

    sipphone_pj_register_thread_if_needed("sipphone");
    status = pjsua_call_get_info((pjsua_call_id)call_id, &call_info);
    if (status != PJ_SUCCESS) {
        return status;
    }

    for (mi = 0; mi < call_info.media_cnt; ++mi) {
        if (call_info.media[mi].type == PJMEDIA_TYPE_AUDIO &&
            call_info.media[mi].status == PJSUA_CALL_MEDIA_ACTIVE)
        {
            call_slot = call_info.media[mi].stream.aud.conf_slot;
            break;
        }
    }

    if (call_slot == PJSUA_INVALID_ID) {
        return PJ_EINVAL;
    }

    return sp_pjsip_start_port_recording(call_slot, path, recorder_id);
}

int32_t sp_pjsip_start_call_local_recording(int32_t call_id, const char *path, int32_t *recorder_id) {
    pjsua_conf_port_id capture_port = sp_capture_conf_port();

    if (path == NULL || recorder_id == NULL) {
        return PJ_EINVAL;
    }

    sipphone_pj_register_thread_if_needed("sipphone");
    (void)call_id;

    if (capture_port == PJSUA_INVALID_ID) {
        return PJ_EINVAL;
    }

    return sp_pjsip_start_port_recording(capture_port, path, recorder_id);
}

int32_t sp_pjsip_stop_call_recording(int32_t call_id, int32_t recorder_id) {
    sipphone_pj_register_thread_if_needed("sipphone");
    (void)call_id;
    return pjsua_recorder_destroy((pjsua_recorder_id)recorder_id);
}

int32_t sp_pjsip_set_sound_devices_with_mode(int32_t capture_id, int32_t playback_id, uint32_t mode) {
    pjsua_snd_dev_param param;

    sipphone_pj_register_thread_if_needed("sipphone");
    pjsua_snd_dev_param_default(&param);
    param.capture_dev = capture_id == SP_INVALID_ID ? PJSUA_SND_DEFAULT_CAPTURE_DEV : capture_id;
    param.playback_dev = playback_id == SP_INVALID_ID ? PJSUA_SND_DEFAULT_PLAYBACK_DEV : playback_id;
    param.mode = mode;
    param.use_default_settings = PJ_FALSE;
    return pjsua_set_snd_dev2(&param);
}

int32_t sp_pjsip_set_extra_capture_device(int32_t capture_id) {
    pjmedia_snd_port_param param;
    pjmedia_aud_dev_index dev_id;
    pj_status_t status;

    sipphone_pj_register_thread_if_needed("sipphone");
    if (g_extra_capture_dev != NULL) {
        pjsua_ext_snd_dev_destroy(g_extra_capture_dev);
        g_extra_capture_dev = NULL;
    }

    dev_id = capture_id == SP_INVALID_ID ? PJMEDIA_AUD_DEFAULT_CAPTURE_DEV : capture_id;
    pjmedia_snd_port_param_default(&param);
    status = pjmedia_aud_dev_default_param(dev_id, &param.base);
    if (status != PJ_SUCCESS) {
        return status;
    }

    param.base.dir = PJMEDIA_DIR_CAPTURE;
    param.base.rec_id = dev_id;
    param.base.clock_rate = 16000;
    param.base.channel_count = 1;
    param.base.samples_per_frame = 320;
    param.base.bits_per_sample = 16;
    param.ec_options = 0;

    return pjsua_ext_snd_dev_create(&param, &g_extra_capture_dev);
}

int32_t sp_pjsip_clear_extra_capture_device(void) {
    sipphone_pj_register_thread_if_needed("sipphone");
    if (g_extra_capture_dev == NULL) {
        return PJ_SUCCESS;
    }

    pjsua_ext_snd_dev_destroy(g_extra_capture_dev);
    g_extra_capture_dev = NULL;
    return PJ_SUCCESS;
}

int32_t sp_pjsip_set_sound_devices(int32_t capture_id, int32_t playback_id) {
    sipphone_pj_register_thread_if_needed("sipphone");
    return pjsua_set_snd_dev(
        capture_id == SP_INVALID_ID ? PJSUA_SND_DEFAULT_CAPTURE_DEV : capture_id,
        playback_id == SP_INVALID_ID ? PJSUA_SND_DEFAULT_PLAYBACK_DEV : playback_id
    );
}

int32_t sp_pjsip_get_sound_devices(int32_t *capture_id, int32_t *playback_id) {
    int cap = PJSUA_SND_DEFAULT_CAPTURE_DEV;
    int play = PJSUA_SND_DEFAULT_PLAYBACK_DEV;
    pj_status_t status;

    sipphone_pj_register_thread_if_needed("sipphone");
    status = pjsua_get_snd_dev(&cap, &play);
    if (capture_id != NULL) {
        *capture_id = (int32_t)cap;
    }
    if (playback_id != NULL) {
        *playback_id = (int32_t)play;
    }
    return status;
}

int32_t sp_pjsip_set_null_sound_device(void) {
    sipphone_pj_register_thread_if_needed("sipphone");
    return pjsua_set_null_snd_dev();
}

int32_t sp_pjsip_get_capture_signal_levels(uint32_t *tx_level, uint32_t *rx_level) {
    return sp_pjsip_get_port_signal_levels((int32_t)sp_capture_conf_port(), tx_level, rx_level);
}

int32_t sp_pjsip_get_port_signal_levels(int32_t port_id, uint32_t *tx_level, uint32_t *rx_level) {
    unsigned tx = 0;
    unsigned rx = 0;
    pj_status_t status;

    sipphone_pj_register_thread_if_needed("sipphone");
    status = pjsua_conf_get_signal_level((pjsua_conf_port_id)port_id, &tx, &rx);
    if (tx_level != NULL) {
        *tx_level = tx;
    }
    if (rx_level != NULL) {
        *rx_level = rx;
    }
    return status;
}

int32_t sp_pjsip_get_call_signal_levels(int32_t call_id, uint32_t *tx_level, uint32_t *rx_level) {
    pjsua_conf_port_id slot;

    sipphone_pj_register_thread_if_needed("sipphone");
    slot = pjsua_call_get_conf_port((pjsua_call_id)call_id);
    if (slot == PJSUA_INVALID_ID) {
        return PJ_EINVAL;
    }

    return sp_pjsip_get_port_signal_levels((int32_t)slot, tx_level, rx_level);
}

int32_t sp_pjsip_play_wav_file(const char *path, int32_t *player_id) {
    pj_str_t file_path;
    pjsua_player_id id = PJSUA_INVALID_ID;
    pjsua_conf_port_id slot;
    pj_status_t status;

    if (path == NULL || player_id == NULL) {
        return PJ_EINVAL;
    }

    sipphone_pj_register_thread_if_needed("sipphone");
    file_path = pj_str((char *)path);
    status = pjsua_player_create(&file_path, 0, &id);
    if (status != PJ_SUCCESS) {
        return status;
    }

    slot = pjsua_player_get_conf_port(id);
    if (slot == PJSUA_INVALID_ID) {
        pjsua_player_destroy(id);
        return PJ_EINVAL;
    }

    status = pjsua_conf_connect(slot, 0);
    if (status != PJ_SUCCESS) {
        pjsua_player_destroy(id);
        return status;
    }

    *player_id = (int32_t)id;
    return PJ_SUCCESS;
}

int32_t sp_pjsip_destroy_player(int32_t player_id) {
    sipphone_pj_register_thread_if_needed("sipphone");
    return pjsua_player_destroy((pjsua_player_id)player_id);
}

int32_t sp_pjsip_get_call_info(int32_t call_id, sp_call_info *info) {
    pjsua_call_info call_info;
    pj_status_t status;

    if (info == NULL) {
        return PJ_EINVAL;
    }

    sipphone_pj_register_thread_if_needed("sipphone");
    status = pjsua_call_get_info((pjsua_call_id)call_id, &call_info);
    if (status != PJ_SUCCESS) {
        return status;
    }

    memset(info, 0, sizeof(*info));
    info->state = sp_map_call_state(call_info.state);
    info->media_status = sp_map_media_status(call_info.media_status);
    info->last_status = (int32_t)call_info.last_status;
    sp_copy_pj_str(info->remote_info, sizeof(info->remote_info), &call_info.remote_info);
    sp_copy_pj_str(info->last_status_text, sizeof(info->last_status_text), &call_info.last_status_text);
    return PJ_SUCCESS;
}

uint32_t sp_pjsip_enum_audio_devices(sp_audio_device_info *info, uint32_t capacity) {
    pjmedia_aud_dev_info devices[64];
    unsigned count = capacity > 64 ? 64 : capacity;
    unsigned i;

    sipphone_pj_register_thread_if_needed("sipphone");
    if (info == NULL || capacity == 0) {
        return 0;
    }

    if (pjsua_enum_aud_devs(devices, &count) != PJ_SUCCESS) {
        return 0;
    }

    for (i = 0; i < count; ++i) {
        memset(&info[i], 0, sizeof(info[i]));
        info[i].id = (int32_t)devices[i].id;
        info[i].input_count = devices[i].input_count;
        info[i].output_count = devices[i].output_count;
        strncpy(info[i].name, devices[i].name, sizeof(info[i].name) - 1);
        strncpy(info[i].driver, devices[i].driver, sizeof(info[i].driver) - 1);
    }

    return count;
}

int32_t sp_pjsip_status_text(int32_t status, char *buffer, uint32_t capacity) {
    if (buffer == NULL || capacity == 0) {
        return PJ_EINVAL;
    }

    sipphone_pj_register_thread_if_needed("sipphone");
    pj_bzero(buffer, capacity);
    pj_strerror((pj_status_t)status, buffer, capacity);
    return PJ_SUCCESS;
}

int32_t sp_pjsip_add_buddy(const char *uri, int32_t account_id, int32_t *buddy_id) {
    pjsua_buddy_config config;
    pjsua_buddy_id id = PJSUA_INVALID_ID;
    pj_status_t status;

    if (uri == NULL || buddy_id == NULL) {
        return PJ_EINVAL;
    }

    sipphone_pj_register_thread_if_needed("sipphone");
    pjsua_buddy_config_default(&config);
    config.uri = pj_str((char *)uri);
    config.subscribe = PJ_TRUE;
    config.acc_id = (pjsua_acc_id)account_id;

    status = pjsua_buddy_add(&config, &id);
    *buddy_id = (int32_t)id;
    return status;
}

int32_t sp_pjsip_delete_buddy(int32_t buddy_id) {
    sipphone_pj_register_thread_if_needed("sipphone");
    if (!pjsua_buddy_is_valid((pjsua_buddy_id)buddy_id)) {
        return PJ_EINVAL;
    }
    return pjsua_buddy_del((pjsua_buddy_id)buddy_id);
}

int32_t sp_pjsip_get_buddy_info(int32_t buddy_id, sp_buddy_info *info) {
    pjsua_buddy_info buddy_info;
    pj_status_t status;

    if (info == NULL) {
        return PJ_EINVAL;
    }

    sipphone_pj_register_thread_if_needed("sipphone");
    status = pjsua_buddy_get_info((pjsua_buddy_id)buddy_id, &buddy_info);
    if (status != PJ_SUCCESS) {
        return status;
    }

    memset(info, 0, sizeof(*info));
    info->id = (int32_t)buddy_info.id;
    info->status = (int32_t)buddy_info.status;
    info->monitor_pres = buddy_info.monitor_pres ? 1 : 0;
    info->sub_state = (int32_t)buddy_info.sub_state;
    info->sub_term_code = buddy_info.sub_term_code;
    sp_copy_pj_str(info->uri, sizeof(info->uri), &buddy_info.uri);
    sp_copy_pj_str(info->status_text, sizeof(info->status_text), &buddy_info.status_text);
    return PJ_SUCCESS;
}
