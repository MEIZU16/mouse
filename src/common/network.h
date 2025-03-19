#ifndef MOUSE_NETWORK_H
#define MOUSE_NETWORK_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "protocol.h"

// 网络连接上下文
typedef struct NetworkContext NetworkContext;

// 设置接收回调函数
typedef void (*MessageCallback)(const Message* msg, size_t msg_size, void* user_data);

// 初始化网络上下文
NetworkContext* network_init(void);

// 释放网络上下文
void network_cleanup(NetworkContext* ctx);

// 服务端：开始监听
bool network_start_server(NetworkContext* ctx, uint16_t port);

// 客户端：连接到服务器
bool network_connect(NetworkContext* ctx, const char* server_ip, uint16_t port);

// 发送消息
bool network_send_message(NetworkContext* ctx, const Message* msg, size_t msg_size);

// 快捷方法：发送鼠标移动消息
bool network_send_mouse_move(NetworkContext* ctx, float rel_x, float rel_y, uint8_t buttons);

// 接收消息，非阻塞，如果没有消息则返回false
bool network_receive_message(NetworkContext* ctx, Message* msg, size_t* msg_size);

// 设置接收回调函数
void network_set_callback(NetworkContext* ctx, MessageCallback callback, void* user_data);

// 断开连接
void network_disconnect(NetworkContext* ctx);

#endif // MOUSE_NETWORK_H 