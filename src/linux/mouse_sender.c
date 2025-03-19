#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>  // 添加对unistd.h的包含，以支持usleep函数
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
    uint8_t current_buttons;       // 当前按钮状态
    
    // 双击检测相关
    GTimer *click_timer;           // 计时器
    gdouble last_click_time;       // 上次点击时间
    gdouble last_click_x;          // 上次点击X坐标
    gdouble last_click_y;          // 上次点击Y坐标
    uint8_t last_click_button;     // 上次点击的按钮
    bool double_click_sent;        // 是否已发送双击
} AppState;

// 函数原型声明
static gboolean on_motion_notify(GtkWidget *widget, GdkEventMotion *event, gpointer data);
static gboolean on_button_press(GtkWidget *widget, GdkEventButton *event, gpointer data);
static gboolean on_button_release(GtkWidget *widget, GdkEventButton *event, gpointer data);
static gboolean on_scroll_event(GtkWidget *widget, GdkEventScroll *event, gpointer data);
GtkWidget *create_window(AppState *state);

// 显示帮助信息
static void show_usage(const char *program_name) {
    printf("用法: %s <服务器IP> [端口] [宽度x高度]\n\n", program_name);
    printf("选项:\n");
    printf("  <服务器IP>           Mac接收端的IP地址\n");
    printf("  [端口]               Mac接收端的端口号（默认：%d）\n", DEFAULT_PORT);
    printf("  [宽度x高度]          指定屏幕分辨率，例如：1920x1080\n");
    printf("\n");
    printf("示例:\n");
    printf("  %s 192.168.1.100                连接到IP为192.168.1.100的Mac，使用默认端口\n", program_name);
    printf("  %s 10.0.0.5 8888                连接到IP为10.0.0.5的Mac，使用端口8888\n", program_name);
    printf("  %s 192.168.1.100 8765 1920x1080 连接到IP为192.168.1.100的Mac，使用分辨率1920x1080\n", program_name);
    printf("\n");
    printf("其他命令:\n");
    printf("  -h, --help           显示此帮助信息\n");
}

// 创建主窗口
GtkWidget *create_window(AppState *state) {
    // 创建窗口
    state->window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(state->window), "鼠标移动捕获器");
    
    // 创建绘图区域
    state->drawing_area = gtk_drawing_area_new();
    gtk_container_add(GTK_CONTAINER(state->window), state->drawing_area);
    
    gtk_widget_set_size_request(state->drawing_area, 800, 600);
    
    // 事件掩码 - 包括鼠标按钮和移动事件
    // 添加滚轮事件掩码
    gtk_widget_add_events(state->drawing_area, 
                         GDK_BUTTON_PRESS_MASK | 
                         GDK_BUTTON_RELEASE_MASK | 
                         GDK_POINTER_MOTION_MASK | 
                         GDK_SCROLL_MASK |         // 普通滚轮事件
                         GDK_SMOOTH_SCROLL_MASK);  // 平滑滚动支持
    
    // 退出时关闭程序
    g_signal_connect(state->window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
    
    // 显示所有窗口部件
    gtk_widget_show_all(state->window);
    
    // 全屏显示
    if (state->fullscreen) {
        gtk_window_fullscreen(GTK_WINDOW(state->window));
    }
    
    // 获取屏幕尺寸（只有在没有通过命令行参数指定时才获取）
    // 注意：这里我们假设如果state->screen_width和state->screen_height已经被设置为
    // 非默认值，则说明用户通过命令行指定了分辨率
    bool use_system_resolution = state->screen_width == 1920 && state->screen_height == 1080;
    
    if (use_system_resolution) {
        GdkDisplay *display = gtk_widget_get_display(state->window);
        if (display) {
            GdkMonitor *monitor = gdk_display_get_primary_monitor(display);
            if (monitor) {
                GdkRectangle workarea;
                gdk_monitor_get_workarea(monitor, &workarea);
                
                // 只有在成功获取到有效值时才更新
                if (workarea.width > 0 && workarea.height > 0) {
                    state->screen_width = workarea.width;
                    state->screen_height = workarea.height;
                    printf("成功获取系统屏幕分辨率: %dx%d\n", state->screen_width, state->screen_height);
                } else {
                    printf("无法获取有效的系统屏幕分辨率，使用默认值: %dx%d\n", 
                           state->screen_width, state->screen_height);
                }
            } else {
                printf("无法获取主监视器，使用默认或指定的分辨率: %dx%d\n", 
                       state->screen_width, state->screen_height);
            }
        } else {
            printf("无法获取显示，使用默认或指定的分辨率: %dx%d\n", 
                   state->screen_width, state->screen_height);
        }
    } else {
        printf("使用指定的屏幕分辨率: %dx%d\n", state->screen_width, state->screen_height);
    }
    
    // 连接鼠标事件处理函数
    g_signal_connect(G_OBJECT(state->drawing_area), "button-press-event", G_CALLBACK(on_button_press), state);
    g_signal_connect(G_OBJECT(state->drawing_area), "button-release-event", G_CALLBACK(on_button_release), state);
    g_signal_connect(G_OBJECT(state->drawing_area), "motion-notify-event", G_CALLBACK(on_motion_notify), state);

    // 连接滚轮事件处理函数
    g_signal_connect(G_OBJECT(state->drawing_area), "scroll-event", G_CALLBACK(on_scroll_event), state);
    
    return state->window;
}

// 鼠标移动回调函数
static gboolean on_motion_notify(GtkWidget *widget G_GNUC_UNUSED, GdkEventMotion *event, gpointer data) {
    AppState *state = (AppState *)data;
    
    if (state->connected) {
        // 计算鼠标相对位置（0.0-1.0）
        // 用鼠标在Linux上的相对位置来控制Mac上的位置
        // 无论屏幕分辨率如何，都将位置归一化为0.0-1.0之间的值
        float rel_x = fmax(0.0, fmin(event->x / state->screen_width, 1.0));
        float rel_y = fmax(0.0, fmin(event->y / state->screen_height, 1.0));
        
        // 记录原始坐标和相对坐标便于调试
        static float last_rel_x = -1, last_rel_y = -1;
        if (fabs(rel_x - last_rel_x) > 0.01 || fabs(rel_y - last_rel_y) > 0.01) {
            printf("发送坐标: 原始=(%.1f, %.1f), 相对=(%.3f, %.3f), 屏幕分辨率=%dx%d\n", 
                   event->x, event->y, rel_x, rel_y, 
                   state->screen_width, state->screen_height);
            last_rel_x = rel_x;
            last_rel_y = rel_y;
        }
        
        // 发送鼠标移动消息，使用当前保存的按钮状态
        network_send_mouse_move(state->network, rel_x, rel_y, state->current_buttons);
    }
    
    return TRUE;
}

// 鼠标按钮回调函数
static gboolean on_button_press(GtkWidget *widget G_GNUC_UNUSED, GdkEventButton *event, gpointer data) {
    AppState *state = (AppState *)data;
    
    if (state->connected) {
        // 计算鼠标相对位置（0.0-1.0）
        float rel_x = fmax(0.0, fmin(event->x / state->screen_width, 1.0));
        float rel_y = fmax(0.0, fmin(event->y / state->screen_height, 1.0));
        
        // 记录原始坐标和相对坐标便于调试
        printf("按下坐标: 原始=(%.1f, %.1f), 相对=(%.3f, %.3f), 屏幕分辨率=%dx%d\n", 
               event->x, event->y, rel_x, rel_y, 
               state->screen_width, state->screen_height);
        
        // 按钮状态（1=左键，2=中键，3=右键）
        uint8_t buttons = 1 << (event->button - 1);
        
        // 获取当前时间
        gdouble current_time = g_timer_elapsed(state->click_timer, NULL);
        
        // 检查是否是双击（同一个按钮，位置接近，时间间隔小于500ms）
        if (event->button == state->last_click_button &&
            fabs(event->x - state->last_click_x) < 5 &&
            fabs(event->y - state->last_click_y) < 5 &&
            (current_time - state->last_click_time) < 0.5 &&
            !state->double_click_sent) {
            
            printf("检测到双击: 按钮=%d, 间隔=%.3f秒\n", 
                   event->button, current_time - state->last_click_time);
                   
            // 发送特殊双击标记 (使用相同的按钮状态，后续Mac端处理)
            // 由于当前协议没有特殊双击字段，我们这里还是发送正常的按下消息
            // Mac端需要根据时间间隔自己判断是否为双击
            
            // 设置已发送双击标记，避免连续多次点击触发多次双击
            state->double_click_sent = true;
        } else {
            // 更新上次点击信息
            state->last_click_time = current_time;
            state->last_click_x = event->x;
            state->last_click_y = event->y;
            state->last_click_button = event->button;
            state->double_click_sent = false;
        }
        
        // 更新当前按钮状态
        state->current_buttons |= buttons;
        
        // 发送鼠标移动消息
        network_send_mouse_move(state->network, rel_x, rel_y, state->current_buttons);
        
        printf("发送按下消息: 按钮=%d, 按钮状态=%d\n", 
               event->button, state->current_buttons);
    }
    
    return TRUE;
}

// 鼠标按钮释放回调函数
static gboolean on_button_release(GtkWidget *widget G_GNUC_UNUSED, GdkEventButton *event, gpointer data) {
    AppState *state = (AppState *)data;
    
    if (state->connected) {
        // 计算鼠标相对位置（0.0-1.0）
        float rel_x = fmax(0.0, fmin(event->x / state->screen_width, 1.0));
        float rel_y = fmax(0.0, fmin(event->y / state->screen_height, 1.0));
        
        // 记录原始坐标和相对坐标便于调试
        printf("释放坐标: 原始=(%.1f, %.1f), 相对=(%.3f, %.3f), 屏幕分辨率=%dx%d\n", 
               event->x, event->y, rel_x, rel_y, 
               state->screen_width, state->screen_height);
        
        // 计算要释放的按钮掩码
        uint8_t button_mask = 1 << (event->button - 1);
        
        // 清除此按钮的状态位
        state->current_buttons &= ~button_mask;
        
        // 发送鼠标移动消息，使用更新后的按钮状态
        network_send_mouse_move(state->network, rel_x, rel_y, state->current_buttons);
        
        printf("发送释放消息: 按钮=%d, 按钮状态=%d\n", 
               event->button, state->current_buttons);
    }
    
    return TRUE;
}

// 鼠标滚轮事件回调函数
static gboolean on_scroll_event(GtkWidget *widget G_GNUC_UNUSED, GdkEventScroll *event, gpointer data) {
    AppState *state = (AppState *)data;
    
    if (state->connected) {
        // 计算鼠标相对位置（0.0-1.0）
        float rel_x = fmax(0.0, fmin(event->x / state->screen_width, 1.0));
        float rel_y = fmax(0.0, fmin(event->y / state->screen_height, 1.0));
        
        // 初始化滚动量 - 简化为方向指示
        float delta_x = 0.0;
        float delta_y = 0.0;
        
        // 根据滚动方向设置简单的值，便于接收端判断
        switch (event->direction) {
            case GDK_SCROLL_UP:
                delta_y = -1.0; // 向上滚动 - 简单的负值
                printf("检测到向上滚动\n");
                break;
            case GDK_SCROLL_DOWN:
                delta_y = 1.0;  // 向下滚动 - 简单的正值
                printf("检测到向下滚动\n");
                break;
            case GDK_SCROLL_LEFT:
                delta_x = -1.0; // 向左滚动 - 简单的负值
                printf("检测到向左滚动\n");
                break;
            case GDK_SCROLL_RIGHT:
                delta_x = 1.0;  // 向右滚动 - 简单的正值
                printf("检测到向右滚动\n");
                break;
            case GDK_SCROLL_SMOOTH:
                // 从事件中获取滚动增量
                gdouble dx = 0.0, dy = 0.0;
                gdk_event_get_scroll_deltas((GdkEvent*)event, &dx, &dy);
                
                // 简化为方向，忽略大小
                if (fabs(dx) > fabs(dy)) {
                    // 水平滚动更明显
                    delta_x = (dx > 0) ? 1.0 : -1.0;
                    printf("检测到平滑滚动（水平方向：%s)\n", delta_x > 0 ? "右" : "左");
                } else if (fabs(dy) > 0.1) {
                    // 垂直滚动更明显
                    delta_y = (dy > 0) ? 1.0 : -1.0;
                    printf("检测到平滑滚动（垂直方向：%s)\n", delta_y > 0 ? "下" : "上");
                }
                break;
            default:
                break;
        }
        
        // 只有在有滚动时才发送事件
        if (delta_x != 0.0 || delta_y != 0.0) {
            // 发送滚轮事件
            printf("发送滚轮事件: 位置=(%.3f, %.3f), 方向值=(%.0f, %.0f)\n", 
                   rel_x, rel_y, delta_x, delta_y);
            
            // 发送滚轮事件
            if (!network_send_scroll(state->network, rel_x, rel_y, delta_x, delta_y)) {
                printf("发送滚轮事件失败\n");
            }
            
            // 延迟一下再发送鼠标移动事件以保持控制
            usleep(10000); // 10ms等待
            network_send_mouse_move(state->network, rel_x, rel_y, state->current_buttons);
        }
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
    state->current_buttons = 0; // 初始化按钮状态为0
    state->screen_width = 1920;  // 默认分辨率
    state->screen_height = 1080; // 默认分辨率
    
    // 初始化双击检测相关参数
    state->click_timer = g_timer_new();
    state->last_click_time = 0;
    state->last_click_x = 0;
    state->last_click_y = 0;
    state->last_click_button = 0;
    state->double_click_sent = false;
    
    // 解析命令行参数
    if (argc < 2 || strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0) {
        show_usage(argv[0]);
        return false;
    }
    
    state->server_ip = argv[1];
    state->port = (argc > 2) ? atoi(argv[2]) : DEFAULT_PORT;
    
    // 解析屏幕分辨率参数（如果提供）
    if (argc > 3) {
        int width, height;
        if (sscanf(argv[3], "%dx%d", &width, &height) == 2) {
            if (width > 0 && height > 0) {
                state->screen_width = width;
                state->screen_height = height;
                printf("使用命令行指定的屏幕分辨率: %dx%d\n", width, height);
            } else {
                fprintf(stderr, "警告: 无效的分辨率格式 '%s'，使用默认分辨率 %dx%d\n", 
                        argv[3], state->screen_width, state->screen_height);
            }
        } else {
            fprintf(stderr, "警告: 无效的分辨率格式 '%s'，使用默认分辨率 %dx%d\n", 
                    argv[3], state->screen_width, state->screen_height);
        }
    }
    
    // 创建主窗口
    create_window(state);
    
    // 如果窗口创建后，系统检测分辨率失败，则使用命令行指定的分辨率
    if (state->screen_width <= 0 || state->screen_height <= 0) {
        fprintf(stderr, "警告: 无法获取屏幕分辨率，使用指定或默认值: %dx%d\n", 
                state->screen_width, state->screen_height);
    }
    
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
    
    // 释放计时器
    if (state->click_timer) {
        g_timer_destroy(state->click_timer);
        state->click_timer = NULL;
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