#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <gtk/gtk.h>
#include <gdk/gdkwayland.h>
#include <wayland-client.h>
#include "../common/network.h"

// 程序状态
typedef struct {
    GtkWidget *window;             // 主窗口
    GtkWidget *drawing_area;       // 绘图区域
    NetworkContext *network;       // 网络上下文
    char *server_ip;               // 服务器IP
    uint16_t port;                 // 服务器端口
    int screen_width;              // 屏幕宽度
    int screen_height;             // 屏幕高度
    bool connected;                // 是否已连接
    bool fullscreen;               // 是否全屏
} AppState;

// 显示帮助信息
static void show_usage(const char *program_name) {
    printf("用法: %s <服务器IP> [端口]\n\n", program_name);
    printf("选项:\n");
    printf("  <服务器IP>           Mac接收端的IP地址\n");
    printf("  [端口]               Mac接收端的端口号（默认：%d）\n", DEFAULT_PORT);
    printf("\n");
    printf("示例:\n");
    printf("  %s 192.168.1.100     连接到IP为192.168.1.100的Mac，使用默认端口\n", program_name);
    printf("  %s 10.0.0.5 8888     连接到IP为10.0.0.5的Mac，使用端口8888\n", program_name);
    printf("\n");
    printf("其他命令:\n");
    printf("  -h, --help           显示此帮助信息\n");
}

// 创建主窗口
static void create_window(AppState *state) {
    // 创建窗口
    state->window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(state->window), "鼠标移动捕获器");
    
    // 设置窗口大小
    gtk_window_set_default_size(GTK_WINDOW(state->window), 800, 600);
    
    // 创建绘图区域
    state->drawing_area = gtk_drawing_area_new();
    gtk_container_add(GTK_CONTAINER(state->window), state->drawing_area);
    
    // 设置事件掩码
    gtk_widget_add_events(state->drawing_area, 
                          GDK_POINTER_MOTION_MASK | 
                          GDK_BUTTON_PRESS_MASK | 
                          GDK_BUTTON_RELEASE_MASK);
    
    // 退出时关闭程序
    g_signal_connect(state->window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
    
    // 显示所有窗口部件
    gtk_widget_show_all(state->window);
    
    // 全屏显示
    if (state->fullscreen) {
        gtk_window_fullscreen(GTK_WINDOW(state->window));
    }
    
    // 获取屏幕尺寸
    GdkDisplay *display = gtk_widget_get_display(state->window);
    if (display) {
        GdkMonitor *monitor = gdk_display_get_primary_monitor(display);
        if (monitor) {
            GdkRectangle workarea;
            gdk_monitor_get_workarea(monitor, &workarea);
            state->screen_width = workarea.width;
            state->screen_height = workarea.height;
        } else {
            // 如果无法获取主监视器，使用默认值
            state->screen_width = 1920;
            state->screen_height = 1080;
            fprintf(stderr, "警告：无法获取主监视器，使用默认分辨率 1920x1080\n");
        }
    } else {
        // 如果无法获取显示，使用默认值
        state->screen_width = 1920;
        state->screen_height = 1080;
        fprintf(stderr, "警告：无法获取显示，使用默认分辨率 1920x1080\n");
    }
}

// 鼠标移动回调函数
static gboolean on_motion_notify(GtkWidget *widget G_GNUC_UNUSED, GdkEventMotion *event, gpointer data) {
    AppState *state = (AppState *)data;
    
    if (state->connected) {
        // 计算鼠标相对位置（0.0-1.0）
        float rel_x = event->x / state->screen_width;
        float rel_y = event->y / state->screen_height;
        
        // 发送鼠标移动消息
        network_send_mouse_move(state->network, rel_x, rel_y, 0);
    }
    
    return TRUE;
}

// 鼠标按钮回调函数
static gboolean on_button_press(GtkWidget *widget G_GNUC_UNUSED, GdkEventButton *event, gpointer data) {
    AppState *state = (AppState *)data;
    
    if (state->connected) {
        // 计算鼠标相对位置（0.0-1.0）
        float rel_x = event->x / state->screen_width;
        float rel_y = event->y / state->screen_height;
        
        // 按钮状态（1=左键，2=中键，3=右键）
        uint8_t buttons = 1 << (event->button - 1);
        
        // 发送鼠标移动消息
        network_send_mouse_move(state->network, rel_x, rel_y, buttons);
    }
    
    return TRUE;
}

// 鼠标按钮释放回调函数
static gboolean on_button_release(GtkWidget *widget G_GNUC_UNUSED, GdkEventButton *event, gpointer data) {
    AppState *state = (AppState *)data;
    
    if (state->connected) {
        // 计算鼠标相对位置（0.0-1.0）
        float rel_x = event->x / state->screen_width;
        float rel_y = event->y / state->screen_height;
        
        // 发送鼠标移动消息，按钮参数设为0表示释放
        network_send_mouse_move(state->network, rel_x, rel_y, 0);
    }
    
    return TRUE;
}

// 连接到服务器
static bool connect_to_server(AppState *state) {
    if (!state->network) {
        state->network = network_init();
        if (!state->network) {
            fprintf(stderr, "无法初始化网络\n");
            return false;
        }
    }
    
    // 连接到服务器
    if (!network_connect(state->network, state->server_ip, state->port)) {
        fprintf(stderr, "无法连接到服务器 %s:%d\n", state->server_ip, state->port);
        return false;
    }
    
    state->connected = true;
    printf("已连接到服务器 %s:%d\n", state->server_ip, state->port);
    
    return true;
}

// 初始化应用程序
static bool init_app(AppState *state, int argc, char **argv) {
    // 初始化GTK
    gtk_init(&argc, &argv);
    
    // 默认值
    state->network = NULL;
    state->connected = false;
    state->fullscreen = true;  // 默认全屏
    
    // 解析命令行参数
    if (argc < 2 || strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        show_usage(argv[0]);
        return false;
    }
    
    state->server_ip = argv[1];
    state->port = (argc > 2) ? atoi(argv[2]) : DEFAULT_PORT;
    
    // 创建主窗口
    create_window(state);
    
    // 连接信号
    g_signal_connect(state->drawing_area, "motion-notify-event", G_CALLBACK(on_motion_notify), state);
    g_signal_connect(state->drawing_area, "button-press-event", G_CALLBACK(on_button_press), state);
    g_signal_connect(state->drawing_area, "button-release-event", G_CALLBACK(on_button_release), state);
    
    // 连接到服务器
    if (!connect_to_server(state)) {
        // 连接失败，但继续运行程序
        fprintf(stderr, "未能连接到服务器，将在GUI启动后重试\n");
    }
    
    return true;
}

// 清理应用程序
static void cleanup_app(AppState *state) {
    if (state->network) {
        network_cleanup(state->network);
        state->network = NULL;
    }
}

// 主函数
int main(int argc, char **argv) {
    AppState state;
    
    // 初始化应用程序
    if (!init_app(&state, argc, argv)) {
        return 1;
    }
    
    // 运行主循环
    gtk_main();
    
    // 清理资源
    cleanup_app(&state);
    
    return 0;
} 