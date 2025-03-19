#ifndef MOUSE_PROTOCOL_H
#define MOUSE_PROTOCOL_H

#include <stdint.h>

// 默认端口号
#define DEFAULT_PORT 8765

// 消息类型
typedef enum {
    MSG_MOUSE_MOVE = 1,    // 鼠标移动消息
    MSG_CONNECT = 2,       // 连接请求
    MSG_DISCONNECT = 3,    // 断开连接
    MSG_HEARTBEAT = 4      // 心跳包
} MessageType;

// 鼠标移动消息
typedef struct {
    uint8_t type;          // 消息类型，值为MSG_MOUSE_MOVE
    float rel_x;           // X轴相对移动（0.0-1.0）
    float rel_y;           // Y轴相对移动（0.0-1.0）
    uint8_t buttons;       // 按钮状态（按位表示）
    uint64_t timestamp;    // 时间戳（毫秒）
} MouseMoveMessage;

// 连接消息
typedef struct {
    uint8_t type;          // 消息类型，值为MSG_CONNECT
    uint32_t version;      // 协议版本
} ConnectMessage;

// 断开连接消息
typedef struct {
    uint8_t type;          // 消息类型，值为MSG_DISCONNECT
    uint8_t reason;        // 断开原因
} DisconnectMessage;

// 心跳包消息
typedef struct {
    uint8_t type;          // 消息类型，值为MSG_HEARTBEAT
    uint64_t timestamp;    // 时间戳（毫秒）
} HeartbeatMessage;

// 统一消息结构
typedef union {
    uint8_t type;
    MouseMoveMessage mouse_move;
    ConnectMessage connect;
    DisconnectMessage disconnect;
    HeartbeatMessage heartbeat;
} Message;

#endif // MOUSE_PROTOCOL_H 