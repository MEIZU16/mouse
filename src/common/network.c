#include "network.h"
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/time.h>

struct NetworkContext {
    int socket_fd;                 // 套接字描述符
    int client_fd;                 // 客户端套接字（仅服务端使用）
    bool is_server;                // 是否是服务端
    bool connected;                // 是否已连接
    MessageCallback callback;      // 消息回调函数
    void* user_data;               // 用户数据（传递给回调函数）
};

// 获取当前时间戳（毫秒）
static uint64_t get_timestamp_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)(tv.tv_sec) * 1000 + (uint64_t)(tv.tv_usec) / 1000;
}

// 初始化网络上下文
NetworkContext* network_init(void) {
    NetworkContext* ctx = (NetworkContext*)malloc(sizeof(NetworkContext));
    if (ctx) {
        memset(ctx, 0, sizeof(NetworkContext));
        ctx->socket_fd = -1;
        ctx->client_fd = -1;
        ctx->is_server = false;
        ctx->connected = false;
        ctx->callback = NULL;
        ctx->user_data = NULL;
    }
    return ctx;
}

// 释放网络上下文
void network_cleanup(NetworkContext* ctx) {
    if (!ctx) return;
    
    network_disconnect(ctx);
    
    free(ctx);
}

// 设置非阻塞模式
static bool set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1) return false;
    
    flags |= O_NONBLOCK;
    if (fcntl(fd, F_SETFL, flags) == -1) return false;
    
    return true;
}

// 服务端：开始监听
bool network_start_server(NetworkContext* ctx, uint16_t port) {
    if (!ctx) return false;
    
    // 断开现有连接
    network_disconnect(ctx);
    
    // 创建套接字
    ctx->socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (ctx->socket_fd < 0) return false;
    
    // 允许地址重用
    int option = 1;
    setsockopt(ctx->socket_fd, SOL_SOCKET, SO_REUSEADDR, &option, sizeof(option));
    
    // 绑定地址
    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(port);
    
    if (bind(ctx->socket_fd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        close(ctx->socket_fd);
        ctx->socket_fd = -1;
        return false;
    }
    
    // 开始监听
    if (listen(ctx->socket_fd, 1) < 0) {
        close(ctx->socket_fd);
        ctx->socket_fd = -1;
        return false;
    }
    
    // 设置非阻塞模式
    if (!set_nonblocking(ctx->socket_fd)) {
        close(ctx->socket_fd);
        ctx->socket_fd = -1;
        return false;
    }
    
    ctx->is_server = true;
    return true;
}

// 客户端：连接到服务器
bool network_connect(NetworkContext* ctx, const char* server_ip, uint16_t port) {
    if (!ctx || !server_ip) return false;
    
    // 断开现有连接
    network_disconnect(ctx);
    
    // 创建套接字
    ctx->socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (ctx->socket_fd < 0) return false;
    
    // 连接到服务器
    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(port);
    
    if (inet_pton(AF_INET, server_ip, &server_addr.sin_addr) <= 0) {
        close(ctx->socket_fd);
        ctx->socket_fd = -1;
        return false;
    }
    
    if (connect(ctx->socket_fd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        close(ctx->socket_fd);
        ctx->socket_fd = -1;
        return false;
    }
    
    // 设置非阻塞模式
    if (!set_nonblocking(ctx->socket_fd)) {
        close(ctx->socket_fd);
        ctx->socket_fd = -1;
        return false;
    }
    
    ctx->is_server = false;
    ctx->connected = true;
    
    // 发送连接消息
    ConnectMessage connect_msg;
    connect_msg.type = MSG_CONNECT;
    connect_msg.version = 1;
    
    Message msg;
    memcpy(&msg, &connect_msg, sizeof(connect_msg));
    
    return network_send_message(ctx, &msg, sizeof(connect_msg));
}

// 服务端：接受客户端连接
static bool accept_client(NetworkContext* ctx) {
    if (!ctx || !ctx->is_server || ctx->socket_fd < 0) return false;
    
    struct sockaddr_in client_addr;
    socklen_t addr_len = sizeof(client_addr);
    
    int client_fd = accept(ctx->socket_fd, (struct sockaddr*)&client_addr, &addr_len);
    if (client_fd < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            // 没有新的连接，非错误
            return true;
        }
        return false;
    }
    
    // 关闭之前的客户端连接
    if (ctx->client_fd >= 0) {
        close(ctx->client_fd);
    }
    
    // 设置非阻塞模式
    if (!set_nonblocking(client_fd)) {
        close(client_fd);
        return false;
    }
    
    ctx->client_fd = client_fd;
    ctx->connected = true;
    
    return true;
}

// 发送消息
bool network_send_message(NetworkContext* ctx, const Message* msg, size_t msg_size) {
    if (!ctx || !msg || msg_size == 0) return false;
    
    if (!ctx->connected) {
        if (ctx->is_server) {
            if (!accept_client(ctx) || !ctx->connected) {
                return false;
            }
        } else {
            return false;
        }
    }
    
    int fd = ctx->is_server ? ctx->client_fd : ctx->socket_fd;
    
    ssize_t sent = send(fd, msg, msg_size, 0);
    if (sent < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            // 缓冲区已满，非错误
            return false;
        }
        ctx->connected = false;
        return false;
    } else if (sent == 0) {
        // 连接已关闭
        ctx->connected = false;
        return false;
    }
    
    return (size_t)sent == msg_size;
}

// 快捷方法：发送鼠标移动消息
bool network_send_mouse_move(NetworkContext* ctx, float rel_x, float rel_y, uint8_t buttons) {
    if (!ctx) return false;
    
    MouseMoveMessage mouse_msg;
    mouse_msg.type = MSG_MOUSE_MOVE;
    mouse_msg.rel_x = rel_x;
    mouse_msg.rel_y = rel_y;
    mouse_msg.buttons = buttons;
    mouse_msg.timestamp = get_timestamp_ms();
    
    Message msg;
    memcpy(&msg, &mouse_msg, sizeof(mouse_msg));
    
    return network_send_message(ctx, &msg, sizeof(mouse_msg));
}

// 接收消息
bool network_receive_message(NetworkContext* ctx, Message* msg, size_t* msg_size) {
    if (!ctx || !msg || !msg_size) return false;
    
    if (!ctx->connected) {
        if (ctx->is_server) {
            if (!accept_client(ctx) || !ctx->connected) {
                return false;
            }
        } else {
            return false;
        }
    }
    
    int fd = ctx->is_server ? ctx->client_fd : ctx->socket_fd;
    
    // 首先接收消息类型（1字节）
    uint8_t type;
    ssize_t received = recv(fd, &type, 1, MSG_PEEK);
    
    if (received < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            // 没有数据，非错误
            return false;
        }
        ctx->connected = false;
        return false;
    } else if (received == 0) {
        // 连接已关闭
        ctx->connected = false;
        return false;
    }
    
    // 根据消息类型确定消息大小
    size_t expected_size;
    switch (type) {
        case MSG_MOUSE_MOVE:
            expected_size = sizeof(MouseMoveMessage);
            break;
        case MSG_CONNECT:
            expected_size = sizeof(ConnectMessage);
            break;
        case MSG_DISCONNECT:
            expected_size = sizeof(DisconnectMessage);
            break;
        case MSG_HEARTBEAT:
            expected_size = sizeof(HeartbeatMessage);
            break;
        default:
            // 未知消息类型
            return false;
    }
    
    // 接收完整消息
    received = recv(fd, msg, expected_size, 0);
    
    if (received < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            // 没有足够的数据，非错误
            return false;
        }
        ctx->connected = false;
        return false;
    } else if (received == 0) {
        // 连接已关闭
        ctx->connected = false;
        return false;
    }
    
    *msg_size = received;
    
    // 调用回调函数
    if (ctx->callback) {
        ctx->callback(msg, *msg_size, ctx->user_data);
    }
    
    return true;
}

// 设置接收回调函数
void network_set_callback(NetworkContext* ctx, MessageCallback callback, void* user_data) {
    if (!ctx) return;
    
    ctx->callback = callback;
    ctx->user_data = user_data;
}

// 断开连接
void network_disconnect(NetworkContext* ctx) {
    if (!ctx) return;
    
    if (ctx->is_server) {
        if (ctx->client_fd >= 0) {
            close(ctx->client_fd);
            ctx->client_fd = -1;
        }
        
        if (ctx->socket_fd >= 0) {
            close(ctx->socket_fd);
            ctx->socket_fd = -1;
        }
    } else {
        if (ctx->socket_fd >= 0) {
            close(ctx->socket_fd);
            ctx->socket_fd = -1;
        }
    }
    
    ctx->connected = false;
} 