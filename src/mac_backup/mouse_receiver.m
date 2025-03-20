#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <math.h>
#include <unistd.h>
#include "../common/network.h"

// 添加IOKit头文件和系统框架
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDParameter.h>
#import <IOKit/hidsystem/event_status_driver.h>
#import <ApplicationServices/ApplicationServices.h>

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
    NSTimeInterval last_message_time; // 最后消息时间
    bool enable_scroll;           // 启用滚轮功能
    int scroll_mode;              // 滚轮控制模式 (0=禁用, 1=标准, 2=原生API)
    NSTimeInterval last_scroll_time; // 最后滚轮事件时间
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

// 处理滚轮事件 - 增加多种实现方法
static void handle_scroll(AppState *state, CGPoint point, float delta_x, float delta_y) {
    // 记录执行开始时间
    NSTimeInterval start_time = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval current_time = start_time;
    
    // 限制滚轮事件频率（每100毫秒最多一次）
    if (current_time - state->last_scroll_time < 0.1) {
        printf("[SCROLL_RATE] 忽略过快的滚轮事件 (间隔: %.3f秒)\n", 
               current_time - state->last_scroll_time);
        return;
    }
    state->last_scroll_time = current_time;
    
    printf("[SCROLL_FUNC] >>> 进入handle_scroll函数, 模式: %d, 参数: point=(%.1f, %.1f), delta=(%.2f, %.2f) <<<\n", 
          state->scroll_mode, point.x, point.y, delta_x, delta_y);
    
    @try {
        // 根据不同模式处理滚轮事件
        switch (state->scroll_mode) {
            case 0: // 禁用模式
                printf("[SCROLL_FUNC] 滚轮功能已禁用\n");
                return;
                
            case 1: { // 标准模式 - 使用CGEventCreateScrollWheelEvent
                // 创建最基本的滚轮事件，使用固定数值1作为滚动单位
                int scroll_y = 0;
                int scroll_x = 0;
                
                // 仅使用方向信息，忽略大小
                if (delta_y > 0) scroll_y = 1;
                else if (delta_y < 0) scroll_y = -1;
                
                if (delta_x > 0) scroll_x = 1;
                else if (delta_x < 0) scroll_x = -1;
                
                printf("[SCROLL_FUNC] 标准模式: 转换后的滚动值: X=%d, Y=%d\n", scroll_x, scroll_y);
                
                // 创建最基本的滚轮事件
                printf("[SCROLL_FUNC] 正在创建CGEvent...\n");
                CGEventRef scrollEvent = NULL;
                
                @try {
                    scrollEvent = CGEventCreateScrollWheelEvent(
                        NULL,                    // 默认源
                        kCGScrollEventUnitLine,  // 使用线单位
                        2,                       // 2轴滚动
                        scroll_y,                // 垂直滚动，固定为±1
                        scroll_x                 // 水平滚动，固定为±1
                    );
                    
                    if (!scrollEvent) {
                        printf("[SCROLL_ERROR] CGEventCreateScrollWheelEvent返回NULL\n");
                        return;
                    }
                    
                    printf("[SCROLL_FUNC] CGEvent创建成功，准备发送\n");
                    
                    // 立即发送事件
                    CGEventPost(kCGHIDEventTap, scrollEvent);
                    printf("[SCROLL_FUNC] CGEventPost调用完成\n");
                    
                    CFRelease(scrollEvent);
                    printf("[SCROLL_FUNC] CGEvent已释放\n");
                } @catch (NSException *exception) {
                    printf("[SCROLL_ERROR] 创建或发送事件时发生异常: %s\n", [exception.reason UTF8String]);
                    
                    if (scrollEvent) {
                        CFRelease(scrollEvent);
                        printf("[SCROLL_FUNC] 异常后释放了CGEvent资源\n");
                    }
                }
                break;
            }
                
            case 2: { // 原生API模式 - 使用NSEvent和postEvent
                printf("[SCROLL_FUNC] 使用原生API模式\n");
                
                // 使用固定滚动单位
                CGFloat scroll_y = delta_y < 0 ? 10.0 : -10.0;
                CGFloat scroll_x = delta_x < 0 ? 10.0 : -10.0;
                
                // 忽略过小的值
                if (fabs(delta_y) < 0.01) scroll_y = 0;
                if (fabs(delta_x) < 0.01) scroll_x = 0;
                
                printf("[SCROLL_FUNC] 原生API模式: 转换后的滚动值: X=%.1f, Y=%.1f\n", scroll_x, scroll_y);
                
                @try {
                    // 创建滚轮事件
                    NSEvent *scrollEvent = [NSEvent 
                        mouseEventWithType:NSEventTypeScrollWheel
                        location:NSMakePoint(point.x, state->screen_height - point.y) // 注意Y坐标系转换
                        modifierFlags:0
                        timestamp:[[NSProcessInfo processInfo] systemUptime]
                        windowNumber:0
                        context:nil
                        eventNumber:0
                        clickCount:0
                        pressure:0
                        buttonNumber:0
                        deltaX:scroll_x
                        deltaY:scroll_y
                        deltaZ:0];
                    
                    if (scrollEvent == nil) {
                        printf("[SCROLL_ERROR] 无法创建NSEvent滚轮事件\n");
                        return;
                    }
                    
                    // 发送事件
                    printf("[SCROLL_FUNC] 正在使用NSEvent.postEvent发送原生滚轮事件\n");
                    [NSEvent postEvent:scrollEvent atStart:YES];
                    printf("[SCROLL_FUNC] NSEvent.postEvent调用完成\n");
                    
                } @catch (NSException *exception) {
                    printf("[SCROLL_ERROR] 使用原生API发送滚轮事件时发生异常: %s\n", 
                          [exception.reason UTF8String]);
                }
                break;
            }
                
            default:
                printf("[SCROLL_ERROR] 未知滚轮模式: %d\n", state->scroll_mode);
                break;
        }
    } @catch (NSException *exception) {
        printf("[SCROLL_ERROR] 处理滚轮事件时发生异常: %s\n", [exception.reason UTF8String]);
    } @finally {
        NSTimeInterval end_time = [[NSDate date] timeIntervalSince1970];
        printf("[SCROLL_FUNC] <<< 退出handle_scroll函数, 执行时间: %.6f秒 >>>\n", 
              end_time - start_time);
    }
}

// 网络状态检查定时器回调
static void check_network_status(AppState *state) {
    NSTimeInterval current_time = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval time_since_last_message = current_time - state->last_message_time;
    
    // 每5秒记录一次状态
    static NSTimeInterval last_status_time = 0;
    if (current_time - last_status_time > 5.0) {
        printf("[NETWORK] 状态检查: 最后消息时间=%.1f秒前, 连接状态=%s\n", 
              time_since_last_message,
              state->network->connected ? "已连接" : "未连接");
        last_status_time = current_time;
    }
    
    // 如果30秒没有消息，尝试重置网络
    if (time_since_last_message > 30.0 && state->network->connected) {
        printf("[NETWORK] 警告: 30秒未收到消息，尝试重置网络连接\n");
        // 这里不真正重置网络，只做记录，避免引入新问题
    }
}

// 处理消息回调
void message_callback(const Message* msg, size_t __unused msg_size, void* user_data) {
    AppState *state = (AppState *)user_data;
    
    // 更新最后消息接收时间
    state->last_message_time = [[NSDate date] timeIntervalSince1970];
    
    // 记录所有类型消息
    printf("[MSG] 收到消息类型: %d, 当前时间: %.3f\n", 
           msg->type, state->last_message_time);
    
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
            
            printf("[SCROLL_DEBUG] >>> 开始处理滚轮消息 ID: %llu, 模式: %d <<<\n", 
                  (unsigned long long)scroll_msg->timestamp, 
                  state->scroll_mode);
            
            // 检查是否启用滚轮功能
            if (!state->enable_scroll || state->scroll_mode == 0) {
                printf("[SCROLL_DEBUG] 滚轮功能已禁用（模式=%d），忽略消息\n", state->scroll_mode);
                return;
            }
            
            // 1. 防止重复处理
            if (scroll_msg->timestamp == state->last_message_id) {
                printf("[SCROLL_DEBUG] 忽略重复的滚轮消息 ID: %llu\n", 
                      (unsigned long long)scroll_msg->timestamp);
                return;
            }
            
            // 2. 详细记录收到的消息内容
            printf("[SCROLL_DEBUG] 接收滚轮消息：时间戳=%llu, deltaX=%.2f, deltaY=%.2f, 位置=(%.3f, %.3f)\n",
                  (unsigned long long)scroll_msg->timestamp,
                  scroll_msg->delta_x, scroll_msg->delta_y,
                  scroll_msg->rel_x, scroll_msg->rel_y);
            
            // 3. 更新最后处理的消息ID
            uint64_t previous_id = state->last_message_id;
            state->last_message_id = scroll_msg->timestamp;
            printf("[SCROLL_DEBUG] 更新消息ID: %llu -> %llu\n", 
                  (unsigned long long)previous_id, 
                  (unsigned long long)state->last_message_id);
            
            // 4. 验证数据有效性
            if (isnan(scroll_msg->delta_x) || isnan(scroll_msg->delta_y) ||
                isinf(scroll_msg->delta_x) || isinf(scroll_msg->delta_y)) {
                printf("[SCROLL_ERROR] 收到无效的滚轮消息: NaN或Inf值 (X=%.2f, Y=%.2f)\n",
                      scroll_msg->delta_x, scroll_msg->delta_y);
                return;
            }
            
            // 5. 检查滚动值，如果太小则忽略
            if (fabs(scroll_msg->delta_x) < 0.001 && fabs(scroll_msg->delta_y) < 0.001) {
                printf("[SCROLL_DEBUG] 忽略无效的滚轮消息: 滚动量太小 (X=%.5f, Y=%.5f)\n",
                      scroll_msg->delta_x, scroll_msg->delta_y);
                return;
            }
            
            // 6. 计算绝对坐标
            float abs_x = fmax(0, fmin(scroll_msg->rel_x * state->screen_width, state->screen_width - 1));
            float abs_y = fmax(0, fmin(scroll_msg->rel_y * state->screen_height, state->screen_height - 1));
            
            // 7. 记录详细信息
            printf("[SCROLL_DEBUG] 准备处理滚轮消息: 位置=(%.1f, %.1f), 滚动量=(%.2f, %.2f)\n", 
                   abs_x, abs_y, scroll_msg->delta_x, scroll_msg->delta_y);
            
            printf("[SCROLL_DEBUG] 尝试调用handle_scroll函数 [模式=%d]...\n", state->scroll_mode);
            
            // 9. 添加异常保护
            @try {
                // 直接处理滚轮事件
                CGPoint point = CGPointMake(abs_x, abs_y);
                handle_scroll(state, point, scroll_msg->delta_x, scroll_msg->delta_y);
                printf("[SCROLL_DEBUG] handle_scroll函数成功执行完毕\n");
            } @catch (NSException *exception) {
                printf("[SCROLL_ERROR] 滚轮处理异常: %s\n", [exception.reason UTF8String]);
                printf("[SCROLL_ERROR] 异常名称: %s\n", [exception.name UTF8String]);
                printf("[SCROLL_ERROR] 调用栈: %s\n", [[exception callStackSymbols] description].UTF8String);
            } @finally {
                printf("[SCROLL_DEBUG] <<< 结束处理滚轮消息 ID: %llu >>>\n", 
                      (unsigned long long)scroll_msg->timestamp);
            }
            
            break;
        }
        
        // 可以添加其他消息类型的处理
        default:
            // 忽略未知的消息类型
            printf("[WARNING] 收到未知消息类型: %d\n", msg->type);
            break;
    }
}

// 初始化应用程序
bool init_app(AppState *state, int argc, const char **argv) {
    // 解析命令行参数
    state->port = DEFAULT_PORT;
    state->scroll_mode = 0; // 默认禁用滚轮
    
    // 处理命令行参数
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            state->port = atoi(argv[i + 1]);
            i++; // 跳过下一个参数
        } 
        else if (strcmp(argv[i], "--scroll") == 0 && i + 1 < argc) {
            state->scroll_mode = atoi(argv[i + 1]);
            i++; // 跳过下一个参数
        }
        else if (strcmp(argv[i], "--enable-scroll") == 0) {
            state->scroll_mode = 1; // 启用标准模式
        }
        else if (strcmp(argv[i], "--native-scroll") == 0) {
            state->scroll_mode = 2; // 启用原生API模式
        }
        else if (isdigit(argv[i][0])) { 
            // 向后兼容，允许直接指定端口
            state->port = atoi(argv[i]);
        }
    }
    
    state->running = false;
    state->last_buttons = 0; // 初始化按钮状态
    state->last_position = CGPointMake(0, 0);
    state->last_move_time = [[NSDate date] timeIntervalSince1970];
    state->last_message_time = state->last_move_time; // 初始化最后消息时间
    state->last_scroll_time = state->last_move_time; // 初始化最后滚轮事件时间
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
    state->enable_scroll = state->scroll_mode > 0; // 根据模式设置是否启用滚轮
    
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
    
    // 输出功能状态
    printf("初始设置: 端口=%d, 滚轮模式=%d (%s), 双击功能=%s\n", 
          state->port,
          state->scroll_mode, 
          state->scroll_mode == 0 ? "禁用" : (state->scroll_mode == 1 ? "标准" : "原生API"),
          state->disable_double_click ? "禁用" : "启用");
    
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
    // 增加网络状态检查计时器
    NSTimer *network_status_timer = [NSTimer scheduledTimerWithTimeInterval:1.0 // 1秒
                                                     repeats:YES
                                                       block:^(NSTimer * __unused timer) {
        check_network_status(state);
    }];
    [[NSRunLoop currentRunLoop] addTimer:network_status_timer forMode:NSRunLoopCommonModes];
    
    // 创建一个计时器，定期检查接收消息
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.01 // 10毫秒
                                                     repeats:YES
                                                       block:^(NSTimer * __unused timer) {
        Message msg;
        size_t msg_size;
        
        // 尝试接收消息
        @try {
            while (network_receive_message(state->network, &msg, &msg_size)) {
                // 消息已在回调函数中处理
            }
        } @catch (NSException *exception) {
            printf("[ERROR] 接收消息时发生异常: %s\n", [exception.reason UTF8String]);
            
            // 尝试恢复网络连接
            printf("[NETWORK] 尝试恢复网络连接...\n");
            // 不实际重置以避免引入更复杂的问题，仅作日志记录
        }
    }];
    
    // 将计时器添加到当前运行循环的通用模式
    [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    
    // 启动NSRunLoop
    [[NSRunLoop currentRunLoop] run];
    
    [timer invalidate];
    [network_status_timer invalidate];
}

// 主函数
int main(int argc, const char **argv) {
    @autoreleasepool {
        // 显示帮助信息
        if (argc > 1 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
            printf("使用方法: %s [选项]\n", argv[0]);
            printf("选项:\n");
            printf("  --port <端口号>       指定监听端口（默认为9876）\n");
            printf("  --scroll <模式>       设置滚轮模式（0=禁用, 1=标准, 2=原生API）\n");
            printf("  --enable-scroll       启用标准滚轮模式（相当于--scroll 1）\n");
            printf("  --native-scroll       启用原生API滚轮模式（相当于--scroll 2）\n");
            printf("  --help, -h            显示此帮助信息\n");
            return 0;
        }
        
        AppState state;
        
        // 初始化应用程序
        if (!init_app(&state, argc, argv)) {
            return 1;
        }
        
        // 确保我们有辅助功能权限
        NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        BOOL isTrusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
        if (!isTrusted) {
            NSAlert *alert = [[NSAlert alloc] init];
            [alert setMessageText:@"需要辅助功能权限"];
            [alert setInformativeText:@"必须授予辅助功能权限以确保滚轮正常工作。请在系统设置中允许此应用程序控制您的电脑，然后重新启动应用程序。"];
            [alert addButtonWithTitle:@"打开系统设置"];
            [alert addButtonWithTitle:@"退出"];
            
            NSModalResponse response = [alert runModal];
            
            if (response == NSAlertFirstButtonReturn) {
                // 打开系统偏好设置中的隐私设置
                NSString *urlString = @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlString]];
                printf("请在系统设置中授予权限后，重新启动本程序\n");
            }
            
            // 无论如何都退出程序，强制用户授予权限后再运行
            printf("未获得辅助功能权限，程序无法正常工作，退出中...\n");
            return 1;
        } else {
            printf("已获得辅助功能权限，所有功能将正常工作\n");
        }
        
        // 运行应用程序
        run_app(&state);
        
        // 清理资源
        cleanup_app(&state);
    }
    
    return 0;
} 