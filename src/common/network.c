#include "network.h"
#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/time.h>
#include <math.h>

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

// 发送消息到网络
bool network_send_message(NetworkContext *ctx, const Message *msg, size_t msg_size) {
    // 检查连接状态
    if (!ctx || !ctx->connected) {
        printf("[NETWORK] 错误: 尝试发送消息但连接未建立\n");
        return false;
    }
    
    // 获取要发送消息的套接字描述符
    int socket_fd = ctx->is_server ? ctx->client_fd : ctx->socket_fd;
    
    // 记录发送状态
    static time_t last_send_failure_time = 0;
    static int send_failures = 0;
    
    // 尝试发送消息
    ssize_t bytes_sent = send(socket_fd, msg, msg_size, MSG_NOSIGNAL);
    
    // 检查发送结果
    if (bytes_sent < 0) {
        // 发送失败
        time_t current_time = time(NULL);
        send_failures++;
        
        // 限制错误输出频率
        if (current_time - last_send_failure_time > 5) {
            printf("[NETWORK] 错误: 发送消息失败，错误码: %d (%s), 累计失败: %d\n", 
                  errno, strerror(errno), send_failures);
            last_send_failure_time = current_time;
        }
        
        // 如果10秒内连续失败超过5次，认为连接已经断开
        if (send_failures >= 5 && current_time - last_send_failure_time <= 10) {
            printf("[NETWORK] 严重错误: 多次发送失败，标记连接为断开\n");
            ctx->connected = false;
        }
        
        return false;
    } else if (bytes_sent < (ssize_t)msg_size) {
        // 部分发送成功
        printf("[NETWORK] 警告: 消息仅部分发送 (%zd/%zu 字节)\n", bytes_sent, msg_size);
        return false;
    } else {
        // 发送成功，重置失败计数
        send_failures = 0;
        return true;
    }
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

// 快捷方法：发送滚轮事件消息
bool network_send_scroll(NetworkContext* ctx, float rel_x, float rel_y, float delta_x, float delta_y) {
    if (!ctx) return false;
    
    // 防止连接中断
    if (!ctx->connected) {
        printf("[ERROR] 发送滚轮事件失败: 连接已断开\n");
        return false;
    }
    
    // 初始化滚轮事件消息
    ScrollMessage scroll_msg;
    memset(&scroll_msg, 0, sizeof(scroll_msg)); // 清零所有字段
    
    scroll_msg.type = MSG_SCROLL;
    scroll_msg.rel_x = rel_x;
    scroll_msg.rel_y = rel_y;
    
    // 仅考虑符号，不考虑大小，统一为±1
    scroll_msg.delta_x = (delta_x > 0) ? 1.0f : ((delta_x < 0) ? -1.0f : 0.0f);
    scroll_msg.delta_y = (delta_y > 0) ? 1.0f : ((delta_y < 0) ? -1.0f : 0.0f);
    
    // 设置时间戳，避免重复消息
    scroll_msg.timestamp = get_timestamp_ms();
    
    // 准备消息
    Message msg;
    memset(&msg, 0, sizeof(msg)); // 清零
    memcpy(&msg, &scroll_msg, sizeof(scroll_msg));
    
    // 打印调试信息
    printf("[DEBUG] 准备发送滚轮事件: X=%s, Y=%s, 时间戳=%llu\n", 
           (scroll_msg.delta_x > 0) ? "右" : ((scroll_msg.delta_x < 0) ? "左" : "无"),
           (scroll_msg.delta_y > 0) ? "下" : ((scroll_msg.delta_y < 0) ? "上" : "无"),
           (unsigned long long)scroll_msg.timestamp);
    
    // 发送消息
    bool result = network_send_message(ctx, &msg, sizeof(scroll_msg));
    
    if (!result) {
        printf("[ERROR] 滚轮事件发送失败\n");
    }
    
    return result;
}

// 根据消息类型获取消息大小
static size_t get_message_size(uint8_t type) {
    switch (type) {
        case MSG_MOUSE_MOVE:
            return sizeof(MouseMoveMessage);
        case MSG_SCROLL:
            return sizeof(ScrollMessage);
        case MSG_CONNECT:
            return sizeof(ConnectMessage);
        case MSG_DISCONNECT:
            return sizeof(DisconnectMessage);
        case MSG_HEARTBEAT:
            return sizeof(HeartbeatMessage);
        default:
            // 未知消息类型
            return 0;
    }
}

// 接收消息回调处理
bool network_receive_message(NetworkContext *ctx, Message *msg, size_t *msg_size) {
    // 检查状态
    if (!ctx || !ctx->connected) {
        return false;
    }
    
    // 获取连接的套接字
    int socket_fd = ctx->is_server ? ctx->client_fd : ctx->socket_fd;
    
    // 检查网络连接状态
    static time_t last_recv_failure_time = 0;
    static int recv_failures = 0;
    
    // 首先接收消息类型
    uint8_t msg_type;
    ssize_t bytes_recv = recv(socket_fd, &msg_type, sizeof(uint8_t), MSG_PEEK | MSG_DONTWAIT);
    
    if (bytes_recv <= 0) {
        // 非阻塞模式下无数据可读，不是错误
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return false;
        }
        
        // 处理接收错误
        time_t current_time = time(NULL);
        recv_failures++;
        
        // 限制错误输出频率
        if (current_time - last_recv_failure_time > 5) {
            if (bytes_recv == 0) {
                printf("[NETWORK] 错误: 连接已关闭\n");
            } else {
                printf("[NETWORK] 错误: 接收消息失败，错误码: %d (%s), 累计失败: %d\n", 
                      errno, strerror(errno), recv_failures);
            }
            last_recv_failure_time = current_time;
        }
        
        // 如果连接已关闭或者10秒内连续失败超过5次，则标记连接断开
        if (bytes_recv == 0 || (recv_failures >= 5 && current_time - last_recv_failure_time <= 10)) {
            printf("[NETWORK] 严重错误: 连接已断开\n");
            ctx->connected = false;
            
            // 如果是服务端，关闭客户端连接并准备接受新连接
            if (ctx->is_server) {
                printf("[NETWORK] 服务端: 准备接受新连接\n");
                close(ctx->client_fd);
                ctx->client_fd = -1;
                
                // 重新开始监听
                network_prepare_server(ctx);
            }
        }
        
        return false;
    }
    
    // 根据消息类型确定消息大小
    size_t expected_size = get_message_size(msg_type);
    if (expected_size == 0) {
        printf("[NETWORK] 错误: 未知消息类型 %d\n", msg_type);
        return false;
    }
    
    // 接收完整消息
    bytes_recv = recv(socket_fd, msg, expected_size, 0);
    if (bytes_recv < (ssize_t)expected_size) {
        printf("[NETWORK] 错误: 消息不完整，接收 %zd/%zu 字节\n", bytes_recv, expected_size);
        return false;
    }
    
    // 接收成功，重置失败计数
    recv_failures = 0;
    
    // 如果设置了回调，调用回调函数
    if (ctx->callback) {
        ctx->callback(msg, expected_size, ctx->user_data);
    }
    
    // 返回消息大小
    if (msg_size) {
        *msg_size = expected_size;
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

// 获取连接状态
bool network_is_connected(NetworkContext* ctx) {
    if (!ctx) return false;
    return ctx->connected;
}

// 重置服务器状态
void network_prepare_server(NetworkContext* ctx) {
    if (!ctx || !ctx->is_server) return;
    
    // 如果客户端套接字仍然打开，关闭它
    if (ctx->client_fd >= 0) {
        close(ctx->client_fd);
        ctx->client_fd = -1;
    }
    
    // 标记为未连接
    ctx->connected = false;
    
    // 确保服务器套接字有效
    if (ctx->socket_fd < 0) {
        // 服务器套接字无效，需要重新创建
        printf("[NETWORK] 服务器套接字无效，将不再接受连接\n");
    } else {
        printf("[NETWORK] 服务器已准备好接受新连接\n");
    }
} 