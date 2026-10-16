#include "agent_link_ble.h"

#include "agent_bridge.h"

#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "os/os_mbuf.h"

static const char *TAG = "link_ble";

#define LINE_MAX_LEN 256
#define REPLY_MAX_LEN 128

// 8f5b0001-6f57-4e28-9b5d-6d1d6f7a1000 service
// 8f5b0002-6f57-4e28-9b5d-6d1d6f7a1000 command (write)
// 8f5b0003-6f57-4e28-9b5d-6d1d6f7a1000 reply (read/notify)
static const ble_uuid128_t SERVICE_UUID = BLE_UUID128_INIT(
    0x00, 0x10, 0x7a, 0x6f, 0x1d, 0x6d, 0x5d, 0x9b,
    0x28, 0x4e, 0x57, 0x6f, 0x01, 0x00, 0x5b, 0x8f);
static const ble_uuid128_t COMMAND_UUID = BLE_UUID128_INIT(
    0x00, 0x10, 0x7a, 0x6f, 0x1d, 0x6d, 0x5d, 0x9b,
    0x28, 0x4e, 0x57, 0x6f, 0x02, 0x00, 0x5b, 0x8f);
static const ble_uuid128_t REPLY_UUID = BLE_UUID128_INIT(
    0x00, 0x10, 0x7a, 0x6f, 0x1d, 0x6d, 0x5d, 0x9b,
    0x28, 0x4e, 0x57, 0x6f, 0x03, 0x00, 0x5b, 0x8f);

typedef struct {
    uint16_t conn_handle;
    char line[LINE_MAX_LEN];
} command_t;

static QueueHandle_t s_commands;
static uint16_t s_reply_handle;
static char s_reply[REPLY_MAX_LEN] = "ready";

static int command_access(uint16_t conn_handle, uint16_t attr_handle,
                          struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR || !s_commands) return BLE_ATT_ERR_UNLIKELY;
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0 || len >= LINE_MAX_LEN) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;

    command_t cmd = { .conn_handle = conn_handle };
    if (ble_hs_mbuf_to_flat(ctxt->om, cmd.line, len, NULL) != 0) return BLE_ATT_ERR_UNLIKELY;
    cmd.line[len] = '\0';
    if (strchr(cmd.line, '\r') || strchr(cmd.line, '\n')) return BLE_ATT_ERR_VALUE_NOT_ALLOWED;
    if (xQueueSend(s_commands, &cmd, 0) != pdTRUE) return BLE_ATT_ERR_INSUFFICIENT_RES;
    return 0;
}

static int reply_access(uint16_t conn_handle, uint16_t attr_handle,
                        struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) return BLE_ATT_ERR_UNLIKELY;
    return os_mbuf_append(ctxt->om, s_reply, strlen(s_reply)) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

static const struct ble_gatt_svc_def SERVICES[] = {{
    .type = BLE_GATT_SVC_TYPE_PRIMARY,
    .uuid = &SERVICE_UUID.u,
    .characteristics = (struct ble_gatt_chr_def[]) {
        {
            .uuid = &COMMAND_UUID.u,
            .access_cb = command_access,
            .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP | BLE_GATT_CHR_F_WRITE_ENC,
        },
        {
            .uuid = &REPLY_UUID.u,
            .access_cb = reply_access,
            .val_handle = &s_reply_handle,
            .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_READ_ENC,
        },
        { 0 },
    },
}, { 0 }};

static void command_task(void *arg)
{
    (void)arg;
    command_t cmd;
    for (;;) {
        if (xQueueReceive(s_commands, &cmd, portMAX_DELAY) != pdTRUE) continue;
        agent_bridge_set_link(AGENT_LINK_BLE, AGENT_LINK_UP, NULL);
        agent_bridge_handle(AGENT_LINK_BLE, cmd.line, s_reply, sizeof(s_reply));

        struct os_mbuf *om = ble_hs_mbuf_from_flat(s_reply, strlen(s_reply));
        if (!om) continue;
        int rc = ble_gatts_notify_custom(cmd.conn_handle, s_reply_handle, om);
        if (rc != 0) ESP_LOGW(TAG, "reply notify failed: %d", rc);
    }
}

esp_err_t agent_link_ble_register(void)
{
    int rc = ble_gatts_count_cfg(SERVICES);
    if (rc == 0) rc = ble_gatts_add_svcs(SERVICES);
    return rc == 0 ? ESP_OK : ESP_FAIL;
}

esp_err_t agent_link_ble_start(void)
{
    if (s_commands) return ESP_OK;
    s_commands = xQueueCreate(8, sizeof(command_t));
    if (!s_commands) return ESP_ERR_NO_MEM;
    agent_bridge_set_link(AGENT_LINK_BLE, AGENT_LINK_WAITING, NULL);
    return xTaskCreate(command_task, "link_ble", 4096, NULL, 5, NULL) == pdPASS
        ? ESP_OK : ESP_ERR_NO_MEM;
}

void agent_link_ble_disconnected(void)
{
    agent_bridge_link_lost(AGENT_LINK_BLE);
    agent_bridge_set_link(AGENT_LINK_BLE, AGENT_LINK_WAITING, NULL);
}
