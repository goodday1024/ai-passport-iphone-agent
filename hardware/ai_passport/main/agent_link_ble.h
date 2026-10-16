#pragma once

#include "esp_err.h"

// Register before the NimBLE host starts; then start the command worker.
esp_err_t agent_link_ble_register(void);
esp_err_t agent_link_ble_start(void);
void agent_link_ble_disconnected(void);
