# Mouse移动同步工具

这个工具允许在Linux（Wayland）上创建一个全屏窗口，捕获鼠标在窗口上的移动路径，并将这些移动同步到Mac上。

## 项目结构

- `src/linux/`: Linux端代码，负责捕获鼠标移动
- `src/mac/`: Mac端代码，负责模拟鼠标移动
- `src/common/`: 共享代码和网络协议定义

## 依赖

### Linux端
- GTK4
- libwayland
- libsocket

### Mac端
- macOS Frameworks (AppKit)

## 编译与运行

### Linux端
```
cd src/linux
make
./mouse-sender
```

### Mac端
```
cd src/mac
make
./mouse-receiver
```

## 使用方法
1. 首先在Mac上运行接收端
2. 然后在Linux上运行发送端
3. Linux上会出现一个全屏窗口，在此窗口中移动鼠标
4. 鼠标移动会实时同步到Mac上 