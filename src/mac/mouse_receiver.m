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
    NSTimeInterval last_move_time;  // 上次移动时间
    NSTimeInterval last_click_time; // 上次点击时间
    bool double_click_pending;    // 双击挂起状态
    int click_count;              // 当前点击次数
    NSTimeInterval button_down_time; // 按钮按下时间
    bool long_press_sent;         // 是否已发送长按事件
    uint64_t last_message_id;     // 最后处理的消息ID
    bool disable_double_click;    // 完全禁用双击功能
    uint64_t last_click_message_id; // 最后点击消息ID
    bool mousedown_sent;          // 是否已发送按下事件
    bool mouseup_sent;            // 是否已发送释放事件
    bool click_processed;         // 当前点击是否已处理
    bool in_drag_mode;            // 是否处于拖动模式
    NSTimer *long_press_timer;    // 长按检测定时器
} AppState;

// 长按检测定时器回调
void long_press_timer_callback(CFRunLoopTimerRef timer, void *info) {
    AppState *state = (AppState *)info;
    if (!state->mousedown_sent || state->mouseup_sent || state->long_press_sent) {
        return; // 不符合长按条件
    }
    
    NSTimeInterval current_time = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval press_duration = current_time - state->button_down_time;
    
    if (press_duration > 0.5) {
        // 超过500毫秒视为长按
        state->long_press_sent = true;
        state->in_drag_mode = true;
        state->double_click_pending = false; // 长按取消双击挂起状态
        
        printf("定时器检测到长按: %.2f秒，启用拖动模式\n", press_duration);
        
        // 发送拖动事件
        CGEventRef event = CGEventCreateMouseEvent(NULL, 
            kCGEventLeftMouseDragged, state->last_position, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, state->click_count);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
}

// 处理鼠标按钮事件
static void handle_mouse_buttons(AppState *state, CGPoint point, uint8_t current_buttons, 
                                uint8_t last_buttons, uint64_t message_id) {
    uint8_t changed_buttons = current_buttons ^ last_buttons;
    NSTimeInterval current_time = [[NSDate date] timeIntervalSince1970];
    bool button_state_changed = false;
    
    // 防止重复处理同一个消息
    if (message_id > 0 && message_id == state->last_message_id) {
        printf("忽略重复消息 ID: %llu\n", message_id);
        return;
    }
    
    if (message_id > 0) {
        state->last_message_id = message_id;
    }
    
    // 左键处理
    if (changed_buttons & 0x01) {
        button_state_changed = true;
        
        if (current_buttons & 0x01) {
            // 如果此时已经处理过点击，忽略重复的按下事件
            if (state->mousedown_sent && !state->mouseup_sent) {
                printf("忽略重复的mousedown事件\n");
                return;
            }
            
            // 左键按下
            // 记录按下时间，用于检测长按
            state->button_down_time = current_time;
            state->long_press_sent = false;
            state->mousedown_sent = true;
            state->mouseup_sent = false;
            state->click_processed = false;
            state->in_drag_mode = false;
            
            // 计算与上次点击的时间间隔
            NSTimeInterval click_interval = current_time - state->last_click_time;
            printf("检测到按下事件，点击间隔: %.3f秒\n", click_interval);
            
            // 检查是否应该触发双击
            if (!state->disable_double_click && 
                click_interval < 0.3 && click_interval > 0.001 && // 排除0时间间隔
                state->double_click_pending) {
                
                state->click_count = 2;
                state->double_click_pending = false;
                printf("触发双击事件 (间隔: %.3f秒)\n", click_interval);
            } else {
                state->click_count = 1;
                printf("触发单击事件\n");
            }
            
            // 创建鼠标按下事件
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
            
            // 设置点击计数
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, state->click_count);
            
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
            
            // 记录最后点击时间
            state->last_click_time = current_time;
            
            // 创建长按检测定时器
            if (state->long_press_timer) {
                CFRunLoopTimerInvalidate(state->long_press_timer);
                CFRelease(state->long_press_timer);
            }
            
            CFRunLoopTimerContext context = {0, state, NULL, NULL, NULL};
            state->long_press_timer = CFRunLoopTimerCreate(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + 0.5, // 0.5秒后触发
                0, // 不重复
                0,
                0,
                long_press_timer_callback,
                &context
            );
            
            if (state->long_press_timer) {
                CFRunLoopAddTimer(CFRunLoopGetCurrent(), state->long_press_timer, kCFRunLoopCommonModes);
                printf("已设置长按检测定时器\n");
            }
        } else {
            // 左键释放
            // 如果没有对应的按下事件，忽略此释放事件
            if (!state->mousedown_sent || state->mouseup_sent) {
                printf("忽略孤立的mouseup事件\n");
                return;
            }
            
            // 取消长按定时器
            if (state->long_press_timer) {
                CFRunLoopTimerInvalidate(state->long_press_timer);
                CFRelease(state->long_press_timer);
                state->long_press_timer = NULL;
            }
            
            state->mousedown_sent = false;
            state->mouseup_sent = true;
            
            // 检查是否是长按后释放
            bool was_long_press = state->long_press_sent;
            bool was_in_drag_mode = state->in_drag_mode;
            
            // 创建鼠标释放事件
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
            
            // 设置点击计数
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, state->click_count);
            
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
            
            // 重置拖动模式
            state->in_drag_mode = false;
            
            // 如果是长按释放，重置点击状态
            if (was_long_press || was_in_drag_mode) {
                state->double_click_pending = false;
                printf("长按或拖动释放: 重置双击状态\n");
            } else if (state->click_count == 1) {
                // 如果是普通单击释放，设置双击挂起状态
                state->double_click_pending = true;
                printf("设置双击挂起状态\n");
            }
            
            // 重置长按状态
            state->long_press_sent = false;
            state->click_processed = true;
        }
    } else if (current_buttons & 0x01) {
        // 左键保持按下
        // 检查是否应该触发长按事件
        NSTimeInterval press_duration = current_time - state->button_down_time;
        
        if (press_duration > 0.5 && !state->long_press_sent && state->mousedown_sent && !state->mouseup_sent) {
            // 超过500毫秒视为长按
            state->long_press_sent = true;
            state->in_drag_mode = true;
            state->double_click_pending = false; // 长按取消双击挂起状态
            
            printf("检测到长按: %.2f秒，启用拖动模式\n", press_duration);
        }
        
        // 如果处于拖动模式或长按状态，发送拖动事件
        if (state->long_press_sent || state->in_drag_mode) {
            // 发送拖动事件
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventLeftMouseDragged, point, kCGMouseButtonLeft);
            
            // 设置点击计数
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, state->click_count);
            
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
            
            printf("发送拖动事件\n");
        }
    }
    
    // 右键处理（简化，不处理双击）
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
    
    // 中键处理（简化，不处理双击）
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
    if (!button_state_changed && 
        current_time - state->last_click_time > 0.5 && 
        state->double_click_pending && 
        !(current_buttons & 0x01)) { // 不在按键按下状态才重置
        
        state->double_click_pending = false;
        printf("超时: 重置双击状态\n");
    }
}

// 处理鼠标移动
static void handle_mouse_move(AppState *state, CGPoint point, uint8_t current_buttons, uint64_t message_id) {
    // 总是移动鼠标到新位置
    CGWarpMouseCursorPosition(point);
    
    // 如果按钮已按下，检查是否为长按
    if (current_buttons & 0x01 && state->mousedown_sent && !state->mouseup_sent) {
        NSTimeInterval current_time = [[NSDate date] timeIntervalSince1970];
        NSTimeInterval press_duration = current_time - state->button_down_time;
        
        // 如果按下时间超过500毫秒且未触发长按，则触发长按
        if (press_duration > 0.5 && !state->long_press_sent) {
            state->long_press_sent = true;
            state->in_drag_mode = true;
            printf("鼠标移动时检测到长按: %.2f秒，启用拖动模式\n", press_duration);
            
            // 取消长按定时器
            if (state->long_press_timer) {
                CFRunLoopTimerInvalidate(state->long_press_timer);
                CFRelease(state->long_press_timer);
                state->long_press_timer = NULL;
            }
        }
        
        // 如果已处于拖动模式，则继续发送拖动事件
        if (state->in_drag_mode) {
            CGEventRef drag_event = CGEventCreateMouseEvent(NULL,
                kCGEventLeftMouseDragged, point, kCGMouseButtonLeft);
            CGEventSetIntegerValueField(drag_event, kCGMouseEventClickState, 1);
            CGEventPost(kCGHIDEventTap, drag_event);
            CFRelease(drag_event);
            printf("持续拖动中...\n");
        }
    }
    
    // 如果没有按钮按下，发送移动事件
    if (current_buttons == 0) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, point, 0);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    } else {
        // 如果有按钮按下，处理按钮状态（包括拖动）
        handle_mouse_buttons(state, point, current_buttons, state->last_buttons, message_id);
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
        
        // 检查消息ID，避免重复处理
        if (mouse_msg->timestamp == state->last_message_id) {
            return;
        }
        
        // 检查按钮状态变化
        bool button_changed = mouse_msg->buttons != state->last_buttons;
        
        // 长按检测（即使按钮没有变化也要检查）
        if ((mouse_msg->buttons & 0x01) && state->mousedown_sent && !state->mouseup_sent) {
            NSTimeInterval current_time = [[NSDate date] timeIntervalSince1970];
            NSTimeInterval press_duration = current_time - state->button_down_time;
            
            // 每次消息来时都检查一下长按状态
            if (press_duration > 0.5 && !state->long_press_sent) {
                state->long_press_sent = true;
                state->in_drag_mode = true;
                printf("消息处理时检测到长按: %.2f秒，启用拖动模式\n", press_duration);
                
                // 取消长按定时器
                if (state->long_press_timer) {
                    CFRunLoopTimerInvalidate(state->long_press_timer);
                    CFRelease(state->long_press_timer);
                    state->long_press_timer = NULL;
                }
            }
        }
        
        // 处理鼠标移动
        if (!button_changed) {
            handle_mouse_move(state, point, mouse_msg->buttons, mouse_msg->timestamp);
        } else {
            // 如果按钮状态变化了，单独处理按钮事件
            handle_mouse_buttons(state, point, mouse_msg->buttons, state->last_buttons, mouse_msg->timestamp);
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
    state->button_down_time = 0;
    state->long_press_sent = false;
    state->last_message_id = 0;
    state->last_click_message_id = 0;
    state->disable_double_click = false; // 启用双击功能
    state->mousedown_sent = false;
    state->mouseup_sent = false;
    state->click_processed = false;
    state->in_drag_mode = false;
    state->long_press_timer = NULL;
    
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
    printf("双击功能和长按功能已启用（定时器版）\n");
    
    return true;
}

// 清理应用程序
void cleanup_app(AppState *state) {
    if (state->network) {
        network_cleanup(state->network);
        state->network = NULL;
    }
    
    if (state->long_press_timer) {
        CFRunLoopTimerInvalidate(state->long_press_timer);
        CFRelease(state->long_press_timer);
        state->long_press_timer = NULL;
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
    
    // 将计时器添加到当前运行循环的通用模式
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    
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