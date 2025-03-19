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
    bool enable_click_detection;  // 启用双击检测
} AppState;

// 全局状态用于定时器回调
static AppState *g_app_state = NULL;

// 注释掉或简化长按检测定时器回调，保留函数以避免编译错误
void long_press_timer_callback(NSTimer *timer) {
    // 不再使用长按检测逻辑
    return;
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
    
    // 左键处理 - 检查左键状态是否改变
    if (changed_buttons & 0x01) {
        button_state_changed = true;
        
        // 左键按下
        if (current_buttons & 0x01) {
            // 如果此时已经处理过点击，忽略重复的按下事件
            if (state->mousedown_sent && !state->mouseup_sent) {
                printf("忽略重复的mousedown事件\n");
                return;
            }
            
            // 记录按下时间
            state->button_down_time = current_time;
            state->long_press_sent = false;
            state->mousedown_sent = true;
            state->mouseup_sent = false;
            state->click_processed = false;
            state->in_drag_mode = true; // 立即进入拖动模式
            state->click_count = 1; // 始终为单击
            
            printf("按钮处理: 左键按下，进入拖动模式，按钮状态: %d\n", current_buttons);
            
            // 创建鼠标按下事件
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
            
            // 设置点击计数
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, state->click_count);
            
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
            
            // 记录最后点击时间
            state->last_click_time = current_time;
            
            // 不再使用长按定时器
            if (state->long_press_timer) {
                [state->long_press_timer invalidate];
                state->long_press_timer = nil;
            }
        } 
        // 左键释放
        else {
            // 如果没有对应的按下事件，忽略此释放事件
            if (!state->mousedown_sent || state->mouseup_sent) {
                printf("忽略孤立的mouseup事件\n");
                return;
            }
            
            // 停止长按检测定时器
            if (state->long_press_timer) {
                [state->long_press_timer invalidate];
                state->long_press_timer = nil;
            }
            
            state->mousedown_sent = false;
            state->mouseup_sent = true;
            
            printf("按钮处理: 左键释放，按钮状态: %d\n", current_buttons);
            
            // 创建鼠标释放事件
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
            
            // 设置点击计数
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, state->click_count);
            
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
            
            // 重置拖动模式
            state->in_drag_mode = false;
            state->long_press_sent = false;
            state->double_click_pending = false;
            state->click_processed = true;
        }
    }
    // 如果左键保持按下状态
    else if ((current_buttons & 0x01) && state->mousedown_sent && !state->mouseup_sent) {
        // 发送拖动事件
        CGEventRef event = CGEventCreateMouseEvent(NULL, 
            kCGEventLeftMouseDragged, point, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
        // 更新最后位置（重要！）
        state->last_position = point;
        printf("按钮处理: 发送拖动事件，按钮状态: %d\n", current_buttons);
    }
    
    // 中键处理
    if (changed_buttons & 0x02) {
        button_state_changed = true;
        
        if (current_buttons & 0x02) {
            // 中键按下
            printf("按钮处理: 中键按下，按钮状态: %d\n", current_buttons);
            
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventOtherMouseDown, point, kCGMouseButtonCenter);
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        } else {
            // 中键释放
            printf("按钮处理: 中键释放，按钮状态: %d\n", current_buttons);
            
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
    
    // 右键处理
    if (changed_buttons & 0x04) {
        button_state_changed = true;
        
        if (current_buttons & 0x04) {
            // 右键按下
            printf("按钮处理: 右键按下，按钮状态: %d\n", current_buttons);
            
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventRightMouseDown, point, kCGMouseButtonRight);
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        } else {
            // 右键释放
            printf("按钮处理: 右键释放，按钮状态: %d\n", current_buttons);
            
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
    
    // 如果Linux告知左键按下，无条件处理为拖动模式
    if (current_buttons & 0x01) {
        // 如果尚未发送按下事件，先发送按下事件
        if (!state->mousedown_sent) {
            // 左键按下
            // 记录按下时间
            NSTimeInterval current_time = [[NSDate date] timeIntervalSince1970];
            state->button_down_time = current_time;
            state->long_press_sent = false;
            state->mousedown_sent = true;
            state->mouseup_sent = false;
            state->click_processed = false;
            state->in_drag_mode = true; // 立即进入拖动模式
            
            printf("鼠标按下，立即进入拖动模式\n");
            
            // 创建鼠标按下事件
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
            
            // 设置点击计数为1
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
            
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        }
        
        // 发送拖动事件
        CGEventRef drag_event = CGEventCreateMouseEvent(NULL,
            kCGEventLeftMouseDragged, point, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(drag_event, kCGMouseEventClickState, 1);
        CGEventPost(kCGHIDEventTap, drag_event);
        CFRelease(drag_event);
        
        printf("发送拖动事件，按钮状态: %d\n", current_buttons);
    } 
    // 如果Linux告知没有按钮按下
    else if (current_buttons == 0) {
        // 如果之前鼠标按下且现在应该释放
        if (state->mousedown_sent && !state->mouseup_sent) {
            // 释放鼠标
            state->mousedown_sent = false;
            state->mouseup_sent = true;
            state->in_drag_mode = false;
            
            printf("鼠标释放，按钮状态: %d\n", current_buttons);
            
            // 创建鼠标释放事件
            CGEventRef event = CGEventCreateMouseEvent(NULL, 
                kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
            
            // 设置点击计数
            CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
            
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        }
        
        // 发送普通的鼠标移动事件
        CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, point, 0);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
        
        printf("发送移动事件，按钮状态: %d\n", current_buttons);
    } 
    else {
        // 其他情况，如右键按下或中键按下
        handle_mouse_buttons(state, point, current_buttons, state->last_buttons, message_id);
    }
    
    // 更新位置
    state->last_position = point;
    state->last_move_time = [[NSDate date] timeIntervalSince1970];
}

// 处理滚轮事件
static void handle_scroll(AppState *state, CGPoint point, float delta_x, float delta_y) {
    // 转换滚动量到macOS期望的范围（约10倍减小使更符合macOS的滚动体验）
    // 注意: macOS滚轮方向与Linux相反
    CGScrollEventUnit unit = kCGScrollEventUnitPixel;  // 使用像素作为单位
    double scaled_delta_x = -delta_x * 0.1;  // 反转并缩放X轴滚动量
    double scaled_delta_y = -delta_y * 0.1;  // 反转并缩放Y轴滚动量
    
    printf("处理滚轮事件: 位置=(%.1f, %.1f), 滚动量=(%.2f, %.2f)\n", 
           point.x, point.y, scaled_delta_x, scaled_delta_y);
    
    // 创建滚轮事件，传入两个轴的滚动量
    CGEventRef scrollEvent = CGEventCreateScrollWheelEvent(
        NULL,              // 默认源
        unit,              // 滚动单位
        2,                 // 滚动轴数量
        (int32_t)scaled_delta_y,  // Y轴滚动量（主滚动轴）
        (int32_t)scaled_delta_x   // X轴滚动量（水平滚动）
    );
    
    // 将滚轮事件发送到系统
    CGEventPost(kCGHIDEventTap, scrollEvent);
    
    // 释放事件对象
    CFRelease(scrollEvent);
    
    // 更新鼠标位置
    state->last_position = point;
}

// 处理消息回调
void message_callback(const Message* msg, size_t __unused msg_size, void* user_data) {
    AppState *state = (AppState *)user_data;
    
    // 处理不同类型的消息
    switch (msg->type) {
        case MSG_MOUSE_MOVE: {
            // 鼠标移动消息处理
            const MouseMoveMessage *mouse_msg = (const MouseMoveMessage *)msg;
            
            // 计算绝对坐标（确保相对位置正确映射到Mac屏幕）
            // 相对位置从Linux端传来，范围为0.0-1.0，表示在屏幕上的相对位置
            CGFloat abs_x = mouse_msg->rel_x * state->screen_width;
            CGFloat abs_y = mouse_msg->rel_y * state->screen_height;
            
            // 修正坐标，确保在屏幕范围内
            abs_x = fmax(0, fmin(abs_x, state->screen_width - 1));
            abs_y = fmax(0, fmin(abs_y, state->screen_height - 1));
            
            // 记录位置信息用于调试
            static CGFloat last_rel_x = -1, last_rel_y = -1;
            if (fabs(mouse_msg->rel_x - last_rel_x) > 0.01 || fabs(mouse_msg->rel_y - last_rel_y) > 0.01) {
                printf("接收到坐标: 相对=(%.3f, %.3f) -> 绝对=(%.1f, %.1f), 屏幕分辨率=%dx%d\n",
                      mouse_msg->rel_x, mouse_msg->rel_y, abs_x, abs_y,
                      state->screen_width, state->screen_height);
                last_rel_x = mouse_msg->rel_x;
                last_rel_y = mouse_msg->rel_y;
            }
            
            CGPoint point = CGPointMake(abs_x, abs_y);
            
            // 检查消息ID，避免重复处理
            if (mouse_msg->timestamp == state->last_message_id) {
                return;
            }
            
            // 保存当前消息ID
            state->last_message_id = mouse_msg->timestamp;
            
            // 输出接收到的原始按钮状态
            printf("接收到消息: 按钮状态=%d\n", mouse_msg->buttons);
            
            // 检查按钮状态变化
            bool button_changed = mouse_msg->buttons != state->last_buttons;
            
            if (button_changed) {
                printf("按钮状态变化：从 %d 变为 %d\n", state->last_buttons, mouse_msg->buttons);
                
                // 获取旧状态
                uint8_t old_buttons = state->last_buttons;
                
                // 更新按钮状态
                state->last_buttons = mouse_msg->buttons;
                
                // 处理按钮事件
                if ((old_buttons & 0x01) == 0 && (mouse_msg->buttons & 0x01)) {
                    // 从未按下变为按下 - 左键按下事件
                    printf("左键按下事件\n");
                    
                    // 记录按下时间
                    NSTimeInterval current_time = [[NSDate date] timeIntervalSince1970];
                    
                    // 检查是否为双击（间隔小于0.5秒）
                    NSTimeInterval click_interval = current_time - state->last_click_time;
                    if (state->enable_click_detection && 
                        click_interval < 0.5 && click_interval > 0.01 && 
                        state->mouseup_sent && 
                        !state->in_drag_mode) {
                        
                        // 这是双击
                        printf("检测到双击，间隔: %.3f秒\n", click_interval);
                        state->click_count = 2;
                    } else {
                        // 普通单击
                        state->click_count = 1;
                    }
                    
                    // 记录时间戳
                    state->button_down_time = current_time;
                    state->last_click_time = current_time;
                    
                    state->long_press_sent = false;
                    state->mousedown_sent = true;
                    state->mouseup_sent = false;
                    state->click_processed = false;
                    state->in_drag_mode = true; // 立即进入拖动模式
                    
                    // 创建鼠标按下事件
                    CGEventRef event = CGEventCreateMouseEvent(NULL, 
                        kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
                    
                    // 设置点击计数
                    CGEventSetIntegerValueField(event, kCGMouseEventClickState, state->click_count);
                    
                    CGEventPost(kCGHIDEventTap, event);
                    CFRelease(event);
                }
                else if ((old_buttons & 0x01) && (mouse_msg->buttons & 0x01) == 0) {
                    // 从按下变为未按下 - 左键释放事件
                    printf("左键释放事件\n");
                    
                    if (state->mousedown_sent && !state->mouseup_sent) {
                        state->mousedown_sent = false;
                        state->mouseup_sent = true;
                        state->in_drag_mode = false;
                        
                        // 创建鼠标释放事件
                        CGEventRef event = CGEventCreateMouseEvent(NULL, 
                            kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
                        
                        // 设置点击计数
                        CGEventSetIntegerValueField(event, kCGMouseEventClickState, state->click_count);
                        
                        CGEventPost(kCGHIDEventTap, event);
                        CFRelease(event);
                        
                        // 重置状态
                        state->long_press_sent = false;
                        state->double_click_pending = false;
                        state->click_processed = true;
                    }
                }
                // 处理其他按钮状态变化
                else {
                    handle_mouse_buttons(state, point, mouse_msg->buttons, old_buttons, mouse_msg->timestamp);
                }
            }
            // 没有按钮状态变化，只有位置变化
            else {
                // 处理位置变化
                // 总是移动鼠标到新位置
                CGWarpMouseCursorPosition(point);
                
                // 如果左键按下状态，发送拖动事件
                if ((mouse_msg->buttons & 0x01) && state->mousedown_sent && !state->mouseup_sent) {
                    // printf("拖动事件\n"); // 减少日志输出
                    
                    // 发送拖动事件
                    CGEventRef drag_event = CGEventCreateMouseEvent(NULL,
                        kCGEventLeftMouseDragged, point, kCGMouseButtonLeft);
                    CGEventSetIntegerValueField(drag_event, kCGMouseEventClickState, state->click_count);
                    CGEventPost(kCGHIDEventTap, drag_event);
                    CFRelease(drag_event);
                }
                // 普通移动
                else if (mouse_msg->buttons == 0) {
                    // 发送普通的鼠标移动事件
                    CGEventRef event = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, point, 0);
                    CGEventPost(kCGHIDEventTap, event);
                    CFRelease(event);
                }
                
                // 更新位置
                state->last_position = point;
                state->last_move_time = [[NSDate date] timeIntervalSince1970];
            }
            break;
        }
        
        case MSG_SCROLL: {
            // 滚轮事件消息处理
            const ScrollMessage *scroll_msg = (const ScrollMessage *)msg;
            
            // 计算绝对坐标
            CGFloat abs_x = scroll_msg->rel_x * state->screen_width;
            CGFloat abs_y = scroll_msg->rel_y * state->screen_height;
            
            // 修正坐标，确保在屏幕范围内
            abs_x = fmax(0, fmin(abs_x, state->screen_width - 1));
            abs_y = fmax(0, fmin(abs_y, state->screen_height - 1));
            
            CGPoint point = CGPointMake(abs_x, abs_y);
            
            // 检查消息ID，避免重复处理
            if (scroll_msg->timestamp == state->last_message_id) {
                return;
            }
            
            // 保存当前消息ID
            state->last_message_id = scroll_msg->timestamp;
            
            // 处理滚轮事件
            handle_scroll(state, point, scroll_msg->delta_x, scroll_msg->delta_y);
            break;
        }
        
        // 可以添加其他消息类型的处理
        default:
            // 忽略未知的消息类型
            break;
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
    state->long_press_timer = nil;
    state->enable_click_detection = true; // 启用点击检测
    
    // 获取屏幕尺寸（主屏幕）
    NSScreen *mainScreen = [NSScreen mainScreen];
    NSRect screenFrame = [mainScreen frame];
    state->screen_width = screenFrame.size.width;
    state->screen_height = screenFrame.size.height;
    
    // 输出所有连接的屏幕信息，帮助调试
    NSArray *screens = [NSScreen screens];
    printf("检测到%lu个屏幕:\n", (unsigned long)[screens count]);
    for (NSUInteger i = 0; i < [screens count]; i++) {
        NSScreen *screen = [screens objectAtIndex:i];
        NSRect frame = [screen frame];
        NSRect visibleFrame = [screen visibleFrame];
        printf("  屏幕%lu: 尺寸=%.0f x %.0f, 可见区域=%.0f x %.0f, 原点=(%.0f, %.0f)\n",
               (unsigned long)i, 
               frame.size.width, frame.size.height,
               visibleFrame.size.width, visibleFrame.size.height,
               frame.origin.x, frame.origin.y);
    }
    
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
    printf("使用主屏幕分辨率: %d x %d\n", state->screen_width, state->screen_height);
    printf("双击功能已启用，即时拖动功能已启用\n");
    printf("已优化为按下即可拖动模式，支持双击检测\n");
    printf("已优化坐标映射，确保Linux和Mac屏幕位置一致\n");
    
    return true;
}

// 清理应用程序
void cleanup_app(AppState *state) {
    if (state->network) {
        network_cleanup(state->network);
        state->network = NULL;
    }
    
    [state->long_press_timer invalidate];
    state->long_press_timer = nil;
    
    state->running = false;
}

// 运行应用程序
void run_app(AppState *state) {
    // 创建一个计时器，定期检查接收消息
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.01 // 10毫秒
                                                     repeats:YES
                                                       block:^(NSTimer * __unused timer) {
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