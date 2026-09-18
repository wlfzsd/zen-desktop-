在zen-desktop的基础上增加了上游代理
1. 运行 构建上游代理版Zen.ps1 生成 D:\Users\Administrator\AppData\Local\Programs\Zen\Zen.exe
2. 在zen.exe目录下 放置 upstream-proxy.txt  内容 http://127.0.0.1:20122   （暂时没写sock5代理，只支持http）
3. 正常运行即可代理

