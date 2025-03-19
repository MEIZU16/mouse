#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include "../common/network.h"

// 应用程序状态
typedef struct {
    NetworkContext *network;      // 网络上下文
    uint16_t port;                // 监听端口
    int screen_width;             // 屏幕宽度
    int screen_height;            // 屏幕高度
    bool running;                 // 运行标志
    uint8_t last_buttons;         // 上次按钮状态
    CGPoint last_position;        // 上次鼠标位置
    NSTimeInterval last_move_time; // 上次移动时间
    NSTimeInterval last_click_time; // 上次点击时间
    bool double_click_pending;    // 双击挂起状态
    int click_count;              // 当前点击次数
} AppState;

// 判断是否为双击
static bool is_double_click(AppState *state, uint8_t button) {
    NSTimeInterval current_time = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval double_click_time = 0.3; // 双击时间窗口(秒)
    
    if (current_time - state->last_click_time < double_click_time && state->double_click_pending) {
        return true;
    }
    
    state->last_click_time = current_time;
    state->double_click_pending = true;
    return false;
}

// 处理鼠标按钮事件
static void handle_mouse_buttons(AppState *state, CGPoint point, uint8_t current_buttons, uint8_t last_buttons) {
    uint8_t changed_buttons = current_buttons ^ last_buttons;
    NSTimeInterval current_time = [[NSDate date] timeIntervalSince1970];
    
    // 左键
    if (changed_buttons & 0x01) {
        if (current_buttons & 0x01) {
            // 左键按下
            if (is_double_click(state, 0x01)) {
                // 双击
                state->click_count = 2;
                state->double_click_pending = false;
            } else {
                // 单击
                state->click_count = 1;
            }
            
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
                
            // 设置点击计数
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, state->click_count);
            
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        } else {
            // 左键释放
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
                
            // 保持相同的点击计数
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, state->click_count);
            
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
            
            // 如果不是双击阶段的第一次点击，重置点击计数
            if (!state->double_click_pending) {
                state->click_count = 0;
            }
        }
    } else if (current_buttons & 0x01) {
        // 左键保持按下，发送拖动事件
        CGEventRef event = CGEventCreateMouseEvent(NULL, 
            kCGEventLeftMouseDragged, point, kCGMouseButtonLeft);
            
        // 保持相同的点击计数
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, state->click_count);
        
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
    
    // 右键
    if (changed_buttons & 0x04) {
        if (current_buttons & 0x04) {
            // 右键按下
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventRightMouseDown, point, kCGMouseButtonRight);
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        } else {
            // 右键释放
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventRightMouseUp, point, kCGMouseButtonRight);
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        }
    } else if (current_buttons & 0x04) {
        // 右键保持按下，发送拖动事件
        CGEventRef event = CGEventCreateMouseEvent(NULL, 
            kCGEventRightMouseDragged, point, kCGMouseButtonRight);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
    
    // 中键
    if (changed_buttons & 0x02) {
        if (current_buttons & 0x02) {
            // 中键按下
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventOtherMouseDown, point, kCGMouseButtonCenter);
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        } else {
            // 中键释放
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventOtherMouseUp, point, kCGMouseButtonCenter);
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        }
    } else if (current_buttons & 0x02) {
        // 中键保持按下，发送拖动事件
        CGEventRef event = CGEventCreateMouseEvent(NULL, 
            kCGEventOtherMouseDragged, point, kCGMouseButtonCenter);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
    
    // 若超过双击时间窗，重置双击状态
    if (current_time - state->last_click_time > 0.5) {
        state->double_click_pending = false;
    }
}

// 处理鼠标移动
static void handle_mouse_move(AppState *state, CGPoint point, uint8_t current_buttons) {
    // 总是移动鼠标到新位置
    CGWarpMouseCursorPosition(point);
    
    // 如果没有按钮按下，发送移动事件
    if (current_buttons == 0) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, point, 0);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    } else {
        // 如果有按钮按下，处理按钮状态（包括拖动）
        handle_mouse_buttons(state, point, current_buttons, state->last_buttons);
    }
    
    // 更新最后位置和时间
    state->last_position = point;
    state->last_move_time = [[NSDate date] timeIntervalSince1970];
}

// 处理消息回调
void message_callback(const Message* msg, size_t msg_size, void* user_data) {
    AppState *state = (AppState *)user_data;
    
    // 只处理鼠标移动消息
    if (msg->type == MSG_MOUSE_MOVE) {
        const MouseMoveMessage *mouse_msg = (const MouseMoveMessage *)msg;
        
        // 计算绝对坐标
        CGFloat abs_x = mouse_msg->rel_x * state->screen_width;
        CGFloat abs_y = mouse_msg->rel_y * state->screen_height;
        CGPoint point = CGPointMake(abs_x, abs_y);
        
        // 处理鼠标移动和按钮
        handle_mouse_move(state, point, mouse_msg->buttons);
        
        // 如果按钮状态变化了，也处理按钮事件
        if (mouse_msg->buttons != state->last_buttons) {
            handle_mouse_buttons(state, point, mouse_msg->buttons, state->last_buttons);
            state->last_buttons = mouse_msg->buttons;
        }
    }
}

// 初始化应用程序
bool init_app(AppState *state, int argc, const char **argv) {
    // 解析命令行参数
    state->port = (argc > 1) ? atoi(argv[1]) : DEFAULT_PORT;
    state->running = false;
    state->last_buttons = 0; // 初始化按钮状态
    state->last_position = CGPointMake(0, 0);
    state->last_move_time = [[NSDate date] timeIntervalSince1970];
    state->last_click_time = 0;
    state->double_click_pending = false;
    state->click_count = 0;
    
    // 获取屏幕尺寸
    NSScreen *mainScreen = [NSScreen mainScreen];
    NSRect screenFrame = [mainScreen frame];
    state->screen_width = screenFrame.size.width;
    state->screen_height = screenFrame.size.height;
    
    // 初始化网络
    state->network = network_init();
    if (!state->network) {
        fprintf(stderr, "无法初始化网络\n");
        return false;
    }
    
    // 设置消息回调
    network_set_callback(state->network, message_callback, state);
    
    // 开始监听
    if (!network_start_server(state->network, state->port)) {
        fprintf(stderr, "无法监听端口 %d\n", state->port);
        network_cleanup(state->network);
        return false;
    }
    
    state->running = true;
    printf("开始监听端口 %d\n", state->port);
    printf("屏幕分辨率: %d x %d\n", state->screen_width, state->screen_height);
    printf("支持双击和长按功能\n");
    
    return true;
}

// 清理应用程序
void cleanup_app(AppState *state) {
    if (state->network) {
        network_cleanup(state->network);
        state->network = NULL;
    }
    
    state->running = false;
}

// 运行应用程序
void run_app(AppState *state) {
    // 创建一个计时器，定期检查接收消息
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.01 // 10毫秒
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
        Message msg;
        size_t msg_size;
        
        // 尝试接收消息
        while (network_receive_message(state->network, &msg, &msg_size)) {
            // 消息已在回调函数中处理
        }
    }];
    
    // 启动NSRunLoop
    [[NSRunLoop currentRunLoop] run];
    
    [timer invalidate];
}

// 主函数
int main(int argc, const char **argv) {
    @autoreleasepool {
        AppState state;
        
        // 初始化应用程序
        if (!init_app(&state, argc, argv)) {
            return 1;
        }
        
        // 请求控制鼠标的权限
        if (!AXIsProcessTrustedWithOptions(NULL)) {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"需要辅助功能权限"];
            [alert setInformativeText:@"请在系统设置中允许此应用程序控制您的电脑"];
            [alert addButtonWithTitle:@"确定"];
            [alert runModal];
            
            // 打开系统偏好设置中的隐私设置
            NSString *urlString = @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
        }
        
        // 运行应用程序
        run_app(&state);
        
        // 清理资源
        cleanup_app(&state);
    }
    
    return 0;
}
