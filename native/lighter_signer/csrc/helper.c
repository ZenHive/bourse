#include "liblighter_signer.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef _WIN32
#include <sys/resource.h>
#endif

#define PROTOCOL_VERSION 1U
#define RESPONSE_HEADER_SIZE 8U
#define MAX_FRAME_SIZE 65535U

enum operation {
  OP_INIT = 1,
  OP_AUTH_TOKEN = 2,
  OP_CREATE_ORDER = 3,
  OP_CANCEL_ORDER = 4,
  OP_CANCEL_ALL_ORDERS = 5,
  OP_MODIFY_ORDER = 6,
  OP_UPDATE_LEVERAGE = 7,
  OP_UPDATE_MARGIN = 8
};

enum error_code {
  ERROR_PROTOCOL = 1,
  ERROR_NOT_INITIALIZED = 2,
  ERROR_ALREADY_INITIALIZED = 3,
  ERROR_INVALID_ARGUMENT = 4,
  ERROR_CLIENT_INITIALIZATION = 5,
  ERROR_SIGNING = 6,
  ERROR_RESPONSE_TOO_LARGE = 7
};

typedef struct {
  const uint8_t *data;
  size_t length;
  size_t offset;
} reader;

static int initialized = 0;
static int api_key_index = 0;
static int64_t account_index = 0;

static void secure_zero(void *pointer, size_t length) {
  volatile uint8_t *bytes = (volatile uint8_t *)pointer;
  while (length-- > 0U) {
    *bytes++ = 0U;
  }
}

static uint16_t read_u16_be(const uint8_t *bytes) {
  return (uint16_t)(((uint16_t)bytes[0] << 8U) | (uint16_t)bytes[1]);
}

static uint32_t read_u32_be(const uint8_t *bytes) {
  return ((uint32_t)bytes[0] << 24U) | ((uint32_t)bytes[1] << 16U) |
         ((uint32_t)bytes[2] << 8U) | (uint32_t)bytes[3];
}

static uint64_t read_u64_be(const uint8_t *bytes) {
  uint64_t value = 0U;
  size_t index;
  for (index = 0U; index < 8U; index++) {
    value = (value << 8U) | bytes[index];
  }
  return value;
}

static void write_u16_be(uint8_t *bytes, uint16_t value) {
  bytes[0] = (uint8_t)(value >> 8U);
  bytes[1] = (uint8_t)value;
}

static void write_u32_be(uint8_t *bytes, uint32_t value) {
  bytes[0] = (uint8_t)(value >> 24U);
  bytes[1] = (uint8_t)(value >> 16U);
  bytes[2] = (uint8_t)(value >> 8U);
  bytes[3] = (uint8_t)value;
}

static int take_bytes(reader *input, size_t length, const uint8_t **value) {
  if (length > input->length - input->offset) {
    return 0;
  }
  *value = input->data + input->offset;
  input->offset += length;
  return 1;
}

static int take_u8(reader *input, uint8_t *value) {
  const uint8_t *bytes;
  if (!take_bytes(input, 1U, &bytes)) {
    return 0;
  }
  *value = bytes[0];
  return 1;
}

static int take_u16(reader *input, uint16_t *value) {
  const uint8_t *bytes;
  if (!take_bytes(input, 2U, &bytes)) {
    return 0;
  }
  *value = read_u16_be(bytes);
  return 1;
}

static int take_u32(reader *input, uint32_t *value) {
  const uint8_t *bytes;
  if (!take_bytes(input, 4U, &bytes)) {
    return 0;
  }
  *value = read_u32_be(bytes);
  return 1;
}

static int take_i64(reader *input, int64_t *value) {
  const uint8_t *bytes;
  if (!take_bytes(input, 8U, &bytes)) {
    return 0;
  }
  *value = (int64_t)read_u64_be(bytes);
  return 1;
}

static int exhausted(const reader *input) { return input->offset == input->length; }

static int read_exact(uint8_t *buffer, size_t length) {
  size_t total = 0U;
  while (total < length) {
    size_t read = fread(buffer + total, 1U, length - total, stdin);
    if (read == 0U) {
      return 0;
    }
    total += read;
  }
  return 1;
}

static uint8_t *read_frame(size_t *length) {
  uint8_t prefix[2];
  uint8_t *frame;
  if (!read_exact(prefix, sizeof(prefix))) {
    return NULL;
  }
  *length = read_u16_be(prefix);
  if (*length == 0U || *length > MAX_FRAME_SIZE) {
    return NULL;
  }
  frame = (uint8_t *)malloc(*length);
  if (frame == NULL || !read_exact(frame, *length)) {
    free(frame);
    return NULL;
  }
  return frame;
}

static int write_frame(const uint8_t *frame, size_t length) {
  uint8_t prefix[2];
  if (length > MAX_FRAME_SIZE) {
    return 0;
  }
  write_u16_be(prefix, (uint16_t)length);
  return fwrite(prefix, 1U, sizeof(prefix), stdout) == sizeof(prefix) &&
         fwrite(frame, 1U, length, stdout) == length && fflush(stdout) == 0;
}

static int write_response_header(uint8_t *frame, uint8_t operation, uint32_t request_id,
                                 uint8_t status) {
  frame[0] = PROTOCOL_VERSION;
  frame[1] = operation;
  write_u32_be(frame + 2U, request_id);
  frame[6] = status;
  frame[7] = 0U;
  return 1;
}

static int send_success(uint8_t operation, uint32_t request_id) {
  uint8_t response[RESPONSE_HEADER_SIZE];
  write_response_header(response, operation, request_id, 0U);
  return write_frame(response, sizeof(response));
}

static int send_error(uint8_t operation, uint32_t request_id, uint8_t code) {
  uint8_t response[RESPONSE_HEADER_SIZE + 1U];
  write_response_header(response, operation, request_id, 1U);
  response[RESPONSE_HEADER_SIZE] = code;
  return write_frame(response, sizeof(response));
}

static void free_string(char *string) {
  if (string != NULL) {
    Free(string);
  }
}

static int send_string_result(uint8_t operation, uint32_t request_id, StrOrErr result) {
  size_t length = result.str == NULL ? 0U : strlen(result.str);
  uint8_t *response;
  int written;
  if (result.err != NULL || result.str == NULL) {
    free_string(result.str);
    free_string(result.err);
    return send_error(operation, request_id, ERROR_SIGNING);
  }
  if (length > UINT16_MAX || RESPONSE_HEADER_SIZE + 2U + length > MAX_FRAME_SIZE) {
    free_string(result.str);
    free_string(result.err);
    return send_error(operation, request_id, ERROR_RESPONSE_TOO_LARGE);
  }
  response = (uint8_t *)malloc(RESPONSE_HEADER_SIZE + 2U + length);
  if (response == NULL) {
    free_string(result.str);
    free_string(result.err);
    return send_error(operation, request_id, ERROR_RESPONSE_TOO_LARGE);
  }
  write_response_header(response, operation, request_id, 0U);
  write_u16_be(response + RESPONSE_HEADER_SIZE, (uint16_t)length);
  memcpy(response + RESPONSE_HEADER_SIZE + 2U, result.str, length);
  written = write_frame(response, RESPONSE_HEADER_SIZE + 2U + length);
  secure_zero(response, RESPONSE_HEADER_SIZE + 2U + length);
  free(response);
  free_string(result.str);
  free_string(result.err);
  return written;
}

static int copy_tx_string(uint8_t *response, size_t *offset, const char *value) {
  size_t length = value == NULL ? 0U : strlen(value);
  if (length > UINT32_MAX || *offset + 4U + length > MAX_FRAME_SIZE) {
    return 0;
  }
  write_u32_be(response + *offset, (uint32_t)length);
  *offset += 4U;
  if (length > 0U) {
    memcpy(response + *offset, value, length);
    *offset += length;
  }
  return 1;
}

static int send_signed_result(uint8_t operation, uint32_t request_id,
                              SignedTxResponse result) {
  uint8_t *response = NULL;
  size_t offset = RESPONSE_HEADER_SIZE;
  int written;
  if (result.err != NULL || result.txInfo == NULL) {
    free_string(result.txInfo);
    free_string(result.txHash);
    free_string(result.messageToSign);
    free_string(result.err);
    return send_error(operation, request_id, ERROR_SIGNING);
  }
  response = (uint8_t *)malloc(MAX_FRAME_SIZE);
  if (response == NULL) {
    free_string(result.txInfo);
    free_string(result.txHash);
    free_string(result.messageToSign);
    free_string(result.err);
    return send_error(operation, request_id, ERROR_RESPONSE_TOO_LARGE);
  }
  write_response_header(response, operation, request_id, 0U);
  response[offset++] = result.txType;
  if (!copy_tx_string(response, &offset, result.txInfo) ||
      !copy_tx_string(response, &offset, result.txHash) ||
      !copy_tx_string(response, &offset, result.messageToSign)) {
    secure_zero(response, MAX_FRAME_SIZE);
    free(response);
    free_string(result.txInfo);
    free_string(result.txHash);
    free_string(result.messageToSign);
    free_string(result.err);
    return send_error(operation, request_id, ERROR_RESPONSE_TOO_LARGE);
  }
  written = write_frame(response, offset);
  secure_zero(response, offset);
  free(response);
  free_string(result.txInfo);
  free_string(result.txHash);
  free_string(result.messageToSign);
  free_string(result.err);
  return written;
}

static int process_init(reader *input, uint8_t operation, uint32_t request_id) {
  uint16_t url_length;
  uint16_t key_length;
  const uint8_t *url_bytes;
  const uint8_t *key_bytes;
  uint32_t chain_id;
  uint8_t api_index;
  int64_t account;
  char *url;
  char *key;
  char *error;
  if (initialized) {
    return send_error(operation, request_id, ERROR_ALREADY_INITIALIZED);
  }
  if (!take_u16(input, &url_length) || !take_bytes(input, url_length, &url_bytes) ||
      !take_u16(input, &key_length) || !take_bytes(input, key_length, &key_bytes) ||
      !take_u32(input, &chain_id) || !take_u8(input, &api_index) ||
      !take_i64(input, &account) || !exhausted(input) || url_length == 0U ||
      key_length == 0U || chain_id > INT_MAX || account <= 0) {
    return send_error(operation, request_id, ERROR_INVALID_ARGUMENT);
  }
  url = (char *)calloc((size_t)url_length + 1U, 1U);
  key = (char *)calloc((size_t)key_length + 1U, 1U);
  if (url == NULL || key == NULL) {
    free(url);
    if (key != NULL) {
      secure_zero(key, (size_t)key_length + 1U);
      free(key);
    }
    return send_error(operation, request_id, ERROR_CLIENT_INITIALIZATION);
  }
  memcpy(url, url_bytes, url_length);
  memcpy(key, key_bytes, key_length);
  error = CreateClient(url, key, (int)chain_id, (int)api_index, (long long)account);
  secure_zero(key, (size_t)key_length + 1U);
  free(key);
  free(url);
  if (error != NULL) {
    free_string(error);
    return send_error(operation, request_id, ERROR_CLIENT_INITIALIZATION);
  }
  initialized = 1;
  api_key_index = (int)api_index;
  account_index = account;
  return send_success(operation, request_id);
}

static int process_auth_token(reader *input, uint8_t operation, uint32_t request_id) {
  int64_t deadline;
  StrOrErr result;
  if (!take_i64(input, &deadline) || !exhausted(input) || deadline < 0) {
    return send_error(operation, request_id, ERROR_INVALID_ARGUMENT);
  }
  result = CreateAuthToken((long long)deadline, api_key_index, (long long)account_index);
  return send_string_result(operation, request_id, result);
}

static int process_create_order(reader *input, uint8_t operation, uint32_t request_id) {
  uint16_t market_index;
  int64_t client_order_index;
  int64_t base_amount;
  uint32_t price;
  uint8_t is_ask;
  uint8_t order_type;
  uint8_t time_in_force;
  uint8_t reduce_only;
  uint32_t trigger_price;
  int64_t order_expiry;
  int64_t integrator_account_index;
  uint32_t taker_fee;
  uint32_t maker_fee;
  uint8_t self_trade_behavior;
  uint8_t self_trade_equality;
  uint8_t skip_nonce;
  int64_t nonce;
  SignedTxResponse result;
  if (!take_u16(input, &market_index) || !take_i64(input, &client_order_index) ||
      !take_i64(input, &base_amount) || !take_u32(input, &price) ||
      !take_u8(input, &is_ask) || !take_u8(input, &order_type) ||
      !take_u8(input, &time_in_force) || !take_u8(input, &reduce_only) ||
      !take_u32(input, &trigger_price) || !take_i64(input, &order_expiry) ||
      !take_i64(input, &integrator_account_index) || !take_u32(input, &taker_fee) ||
      !take_u32(input, &maker_fee) || !take_u8(input, &self_trade_behavior) ||
      !take_u8(input, &self_trade_equality) || !take_u8(input, &skip_nonce) ||
      !take_i64(input, &nonce) || !exhausted(input) || market_index > INT16_MAX ||
      taker_fee > INT_MAX || maker_fee > INT_MAX || is_ask > 1U || reduce_only > 1U ||
      skip_nonce > 1U || nonce < 0) {
    return send_error(operation, request_id, ERROR_INVALID_ARGUMENT);
  }
  result = SignCreateOrder((int)market_index, (long long)client_order_index,
                           (long long)base_amount, (int)price, (int)is_ask,
                           (int)order_type, (int)time_in_force, (int)reduce_only,
                           (int)trigger_price, (long long)order_expiry,
                           (long long)integrator_account_index, (int)taker_fee,
                           (int)maker_fee, self_trade_behavior, self_trade_equality,
                           skip_nonce, (long long)nonce, api_key_index,
                           (long long)account_index);
  return send_signed_result(operation, request_id, result);
}

static int process_cancel_order(reader *input, uint8_t operation, uint32_t request_id) {
  uint16_t market_index;
  int64_t order_index;
  uint8_t skip_nonce;
  int64_t nonce;
  SignedTxResponse result;
  if (!take_u16(input, &market_index) || !take_i64(input, &order_index) ||
      !take_u8(input, &skip_nonce) || !take_i64(input, &nonce) || !exhausted(input) ||
      market_index > INT16_MAX || skip_nonce > 1U || nonce < 0) {
    return send_error(operation, request_id, ERROR_INVALID_ARGUMENT);
  }
  result = SignCancelOrder((int)market_index, (long long)order_index, skip_nonce,
                           (long long)nonce, api_key_index, (long long)account_index);
  return send_signed_result(operation, request_id, result);
}

static int process_cancel_all_orders(reader *input, uint8_t operation,
                                     uint32_t request_id) {
  uint8_t time_in_force;
  int64_t time;
  uint16_t market_index;
  uint8_t skip_nonce;
  int64_t nonce;
  SignedTxResponse result;
  if (!take_u8(input, &time_in_force) || !take_i64(input, &time) ||
      !take_u16(input, &market_index) || !take_u8(input, &skip_nonce) ||
      !take_i64(input, &nonce) || !exhausted(input) || market_index > INT16_MAX ||
      skip_nonce > 1U || nonce < 0) {
    return send_error(operation, request_id, ERROR_INVALID_ARGUMENT);
  }
  result = SignCancelAllOrders((int)time_in_force, (long long)time, (int)market_index,
                               skip_nonce, (long long)nonce, api_key_index,
                               (long long)account_index);
  return send_signed_result(operation, request_id, result);
}

static int process_modify_order(reader *input, uint8_t operation, uint32_t request_id) {
  uint16_t market_index;
  int64_t index;
  int64_t base_amount;
  int64_t price;
  int64_t trigger_price;
  int64_t integrator_account_index;
  uint32_t taker_fee;
  uint32_t maker_fee;
  uint8_t self_trade_behavior;
  uint8_t self_trade_equality;
  uint8_t skip_nonce;
  int64_t nonce;
  SignedTxResponse result;
  if (!take_u16(input, &market_index) || !take_i64(input, &index) ||
      !take_i64(input, &base_amount) || !take_i64(input, &price) ||
      !take_i64(input, &trigger_price) || !take_i64(input, &integrator_account_index) ||
      !take_u32(input, &taker_fee) || !take_u32(input, &maker_fee) ||
      !take_u8(input, &self_trade_behavior) || !take_u8(input, &self_trade_equality) ||
      !take_u8(input, &skip_nonce) || !take_i64(input, &nonce) || !exhausted(input) ||
      market_index > INT16_MAX || price < 0 || price > UINT32_MAX ||
      trigger_price < 0 || trigger_price > UINT32_MAX || taker_fee > INT_MAX ||
      maker_fee > INT_MAX || skip_nonce > 1U || nonce < 0) {
    return send_error(operation, request_id, ERROR_INVALID_ARGUMENT);
  }
  result = SignModifyOrder((int)market_index, (long long)index, (long long)base_amount,
                           (long long)price, (long long)trigger_price,
                           (long long)integrator_account_index, (int)taker_fee,
                           (int)maker_fee, self_trade_behavior, self_trade_equality,
                           skip_nonce, (long long)nonce, api_key_index,
                           (long long)account_index);
  return send_signed_result(operation, request_id, result);
}

static int process_update_leverage(reader *input, uint8_t operation,
                                   uint32_t request_id) {
  uint16_t market_index;
  uint32_t margin_fraction;
  uint8_t margin_mode;
  uint8_t skip_nonce;
  int64_t nonce;
  SignedTxResponse result;
  if (!take_u16(input, &market_index) || !take_u32(input, &margin_fraction) ||
      !take_u8(input, &margin_mode) || !take_u8(input, &skip_nonce) ||
      !take_i64(input, &nonce) || !exhausted(input) || market_index > INT16_MAX ||
      margin_fraction > UINT16_MAX || skip_nonce > 1U || nonce < 0) {
    return send_error(operation, request_id, ERROR_INVALID_ARGUMENT);
  }
  result = SignUpdateLeverage((int)market_index, (int)margin_fraction, (int)margin_mode,
                              skip_nonce, (long long)nonce, api_key_index,
                              (long long)account_index);
  return send_signed_result(operation, request_id, result);
}

static int process_update_margin(reader *input, uint8_t operation, uint32_t request_id) {
  uint16_t market_index;
  int64_t usdc_amount;
  uint8_t direction;
  uint8_t skip_nonce;
  int64_t nonce;
  SignedTxResponse result;
  if (!take_u16(input, &market_index) || !take_i64(input, &usdc_amount) ||
      !take_u8(input, &direction) || !take_u8(input, &skip_nonce) ||
      !take_i64(input, &nonce) || !exhausted(input) || market_index > INT16_MAX ||
      skip_nonce > 1U || nonce < 0) {
    return send_error(operation, request_id, ERROR_INVALID_ARGUMENT);
  }
  result = SignUpdateMargin((int)market_index, (long long)usdc_amount, (int)direction,
                            skip_nonce, (long long)nonce, api_key_index,
                            (long long)account_index);
  return send_signed_result(operation, request_id, result);
}

static int process_frame(const uint8_t *frame, size_t length) {
  reader input = {frame, length, 0U};
  uint8_t version;
  uint8_t operation;
  uint32_t request_id;
  if (!take_u8(&input, &version) || !take_u8(&input, &operation) ||
      !take_u32(&input, &request_id) || version != PROTOCOL_VERSION) {
    return send_error(0U, 0U, ERROR_PROTOCOL);
  }
  if (operation == OP_INIT) {
    return process_init(&input, operation, request_id);
  }
  if (!initialized) {
    return send_error(operation, request_id, ERROR_NOT_INITIALIZED);
  }
  switch (operation) {
  case OP_AUTH_TOKEN:
    return process_auth_token(&input, operation, request_id);
  case OP_CREATE_ORDER:
    return process_create_order(&input, operation, request_id);
  case OP_CANCEL_ORDER:
    return process_cancel_order(&input, operation, request_id);
  case OP_CANCEL_ALL_ORDERS:
    return process_cancel_all_orders(&input, operation, request_id);
  case OP_MODIFY_ORDER:
    return process_modify_order(&input, operation, request_id);
  case OP_UPDATE_LEVERAGE:
    return process_update_leverage(&input, operation, request_id);
  case OP_UPDATE_MARGIN:
    return process_update_margin(&input, operation, request_id);
  default:
    return send_error(operation, request_id, ERROR_PROTOCOL);
  }
}

static void harden_process(void) {
#ifndef _WIN32
  struct rlimit core_limit = {0U, 0U};
  (void)setrlimit(RLIMIT_CORE, &core_limit);
  if (freopen("/dev/null", "w", stderr) == NULL) {
    /* best-effort hardening: keep running with stderr unredirected */
  }
#else
  if (freopen("NUL", "w", stderr) == NULL) {
    /* best-effort hardening: keep running with stderr unredirected */
  }
#endif
  (void)setvbuf(stdin, NULL, _IONBF, 0U);
  (void)setvbuf(stdout, NULL, _IONBF, 0U);
}

int main(void) {
  harden_process();
  for (;;) {
    size_t length = 0U;
    uint8_t *frame = read_frame(&length);
    int keep_running;
    if (frame == NULL) {
      return 0;
    }
    keep_running = process_frame(frame, length);
    secure_zero(frame, length);
    free(frame);
    if (!keep_running) {
      return 1;
    }
  }
}
