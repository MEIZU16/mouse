#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <linux/input.h>
#include <string.h>
#include <dirent.h>
#include <pthread.h>
#include <math.h>
#include <errno.h>
#include "../common/network.h"

// 全局状态
static volatile sig_atomic_t running = 1;
static NetworkContext *network = NULL;
static pthread_t send_thread;
static double last_rel_x = 0.0;
static double last_rel_y = 0.0;
static uint8_t button_state = 0; // 全局按钮状态
static uint8_t last_sent_button_state = 0; // 上次发送的按钮状态
static double move_threshold = 0.001; // 移动阈值
static int screen_width = 1920;    // 默认屏幕宽度
static int screen_height = 1080;   // 默认屏幕高度
static uint64_t message_counter = 1; // 消息计数器，从1开始
static bool force_send = false;    // 强制发送标志

// 信号处理
void handle_signal(int sig) {
    (void)sig; // 避免未使用警告
    running = 0;
}

// 查找鼠标设备
char *find_mouse_device() {
    DIR *dir;
    struct dirent *entry;
    static char device_path[256];
    int fd;
    char name[256];
    
    // 打开/dev/input目录
    dir = opendir("/dev/input");
    if (!dir) {
        perror("无法打开/dev/input目录");
        return NULL;
    }
    
    // 遍历所有event设备
    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, "event", 5) == 0) {
            snprintf(device_path, sizeof(device_path), "/dev/input/%s", entry->d_name);
            
            fd = open(device_path, O_RDONLY);
            if (fd < 0) continue;
            
            // 获取设备名称
            if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0) {
                if (strstr(name, "Mouse") || strstr(name, "mouse")) {
                    printf("找到鼠标设备: %s (%s)\n", device_path, name);
                    close(fd);
                    closedir(dir);
                    return device_path;
                }
            }
            close(fd);
        }
    }
    
    closedir(dir);
    return NULL;
}

// 发送线程函数
void *send_thread_func(void *arg) {
    (void)arg; // 避免未使用警告
    
    while (running) {
        // 准备消息
        MouseMoveMessage msg;
        msg.type = MSG_MOUSE_MOVE; // 修正：直接设置type字段，而不是header.type
        msg.rel_x = last_rel_x;
        msg.rel_y = last_rel_y;
        msg.buttons = button_state;
        msg.timestamp = message_counter;
        
        // 决定是否发送消息
        // 1. 位置发生变化且超过阈值
        // 2. 按钮状态发生变化
        // 3. 强制发送标志为真
        if (force_send || button_state != last_sent_button_state) {
            // 发送消息
            if (network_send_message(network, (Message*)&msg, sizeof(msg)) == 0) { // 修正：添加消息大小参数
                printf("发送鼠标移动消息: x=%.2f, y=%.2f, 按钮=%u, ID=%lu\n", 
                       msg.rel_x, msg.rel_y, msg.buttons, (unsigned long)msg.timestamp); // 修正：使用正确的格式说明符
                
                // 更新上次发送的按钮状态
                last_sent_button_state = button_state;
                message_counter++; // 修改：直接更新计数器，不需要中间变量
                force_send = false;
            } else {
                fprintf(stderr, "发送消息失败\n");
            }
        }
        
        // 休眠一段时间
        usleep(10000); // 10毫秒
    }
    
    return NULL;
}

// 处理鼠标事件
void process_mouse_event(struct input_event *ev, double screen_width, double screen_height) {
    (void)screen_width;  // 避免未使用警告
    (void)screen_height; // 避免未使用警告
    
    static int dx = 0, dy = 0;
    static bool moved = false;
    
    if (ev->type == EV_REL) {
        // 鼠标相对移动
        if (ev->code == REL_X) {
            dx += ev->value;
            moved = true;
        } else if (ev->code == REL_Y) {
            dy += ev->value;
            moved = true;
        }
    } else if (ev->type == EV_KEY) {
        // 按键事件
        if (ev->code == BTN_LEFT) {
            // 左键
            if (ev->value) {
                button_state |= 0x01; // 按下
                printf("左键按下, 按钮状态: %d\n", button_state);
            } else {
                button_state &= ~0x01; // 释放
                printf("左键释放, 按钮状态: %d\n", button_state);
            }
            force_send = true; // 强制发送按键事件
        } else if (ev->code == BTN_MIDDLE) {
            // 中键
            if (ev->value) {
                button_state |= 0x02; // 按下
                printf("中键按下, 按钮状态: %d\n", button_state);
            } else {
                button_state &= ~0x02; // 释放
                printf("中键释放, 按钮状态: %d\n", button_state);
            }
            force_send = true; // 强制发送按键事件
        } else if (ev->code == BTN_RIGHT) {
            // 右键
            if (ev->value) {
                button_state |= 0x04; // 按下
                printf("右键按下, 按钮状态: %d\n", button_state);
            } else {
                button_state &= ~0x04; // 释放
                printf("右键释放, 按钮状态: %d\n", button_state);
            }
            force_send = true; // 强制发送按键事件
        }
    } else if (ev->type == EV_SYN && moved) {
        // 同步事件，处理累积的移动
        double rel_x = (double)dx / 1000.0;
        double rel_y = (double)dy / 1000.0;
        
        // 计算相对屏幕位置
        last_rel_x += rel_x;
        last_rel_y += rel_y;
        
        // 确保值在0.0-1.0范围内
        if (last_rel_x < 0.0) last_rel_x = 0.0;
        if (last_rel_x > 1.0) last_rel_x = 1.0;
        if (last_rel_y < 0.0) last_rel_y = 0.0;
        if (last_rel_y > 1.0) last_rel_y = 1.0;
        
        // 如果移动足够大，设置force_send为true
        if (fabs(rel_x) > move_threshold || fabs(rel_y) > move_threshold) { // 修正：使用fabs替代abs
            force_send = true;
        }
        
        // 重置累积值
        dx = 0;
        dy = 0;
        moved = false;
    }
}

int main(int argc, char **argv) {
    char *device_path;
    int fd;
    uint16_t port = DEFAULT_PORT;
    char server_address[256] = "127.0.0.1"; // 默认为本地回环地址
    
    // 处理命令行参数
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) {
            port = atoi(argv[i + 1]);
            i++;
        } else if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) {
            strncpy(server_address, argv[i + 1], sizeof(server_address) - 1);
            i++;
        } else if (strcmp(argv[i], "-r") == 0 && i + 2 < argc) {
            screen_width = atoi(argv[i + 1]);
            screen_height = atoi(argv[i + 2]);
            i += 2;
        }
    }
    
    printf("服务器: %s, 端口: %d\n", server_address, port);
    printf("目标屏幕分辨率: %d x %d\n", screen_width, screen_height);
    
    // 设置信号处理
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    
    // 查找鼠标设备
    device_path = find_mouse_device();
    if (!device_path) {
        fprintf(stderr, "未找到鼠标设备\n");
        return 1;
    }
    
    // 打开鼠标设备
    fd = open(device_path, O_RDONLY);
    if (fd < 0) {
        perror("无法打开鼠标设备");
        return 1;
    }
    
    // 初始化网络
    network = network_init();
    if (!network) {
        fprintf(stderr, "无法初始化网络\n");
        close(fd);
        return 1;
    }
    
    // 连接到服务器
    if (!network_connect(network, server_address, port)) {
        fprintf(stderr, "无法连接到服务器 %s:%d\n", server_address, port);
        network_cleanup(network);
        close(fd);
        return 1;
    }
    
    printf("已连接到服务器 %s:%d\n", server_address, port);
    
    // 创建发送线程
    pthread_create(&send_thread, NULL, send_thread_func, NULL);
    
    // 主事件循环
    while (running) {
        struct input_event ev;
        ssize_t n = read(fd, &ev, sizeof(ev));
        
        if (n == sizeof(ev)) {
            process_mouse_event(&ev, screen_width, screen_height);
        } else if (n < 0 && errno != EINTR) {
            perror("读取鼠标事件失败");
            break;
        }
    }
    
    // 等待发送线程结束
    pthread_join(send_thread, NULL);
    
    // 清理
    network_cleanup(network);
    close(fd);
    
    printf("程序正常退出\n");
    return 0;
} 