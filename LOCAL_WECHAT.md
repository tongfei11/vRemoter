# 本机微信输入法适配 · 编译 0125

控制台“语音输入法”可切换微信和豆包，默认微信。切换会停止当前录音。

- 微信：微信输入法设置 → 语音输入 → 按住说话设为 Fn，麦克风选 vRemoteDr 2ch。遥控器按住说，松手结束；不实现豆包式短按持续说话。
- 豆包：保留原来的按键切换及录音状态确认。
- 系统默认录音设备保留真实麦克风。选择虚拟麦克风后，微信键盘语音也经 vRemoter 音频通道；需要原来的独立键盘语音时，将微信的麦克风切回真实麦克风。
- 未接 ASR 接口。微信负责识别；最终长按收音与出字必须用真实遥控器验收。

`zsh Scripts/build-local.sh` 构建本机可执行文件 `.build/vRemote-local`（不生成分发包，本机构建不启用上游遥测 SDK）。

验证：

```
swiftc Sources/vRemote/HoldVoiceSession.swift SelfTests/WeChat/main.swift -o /tmp/wechat-test
/tmp/wechat-test
.build/vRemote-local --voice-session-self-test
zsh Scripts/run-self-tests.sh
```

## HID 共享模式（0125）

采用上游 PR #10 的回退思路：独占访问返回 NotPrivileged 时，释放失败的管理器后新建共享管理器。映射可发送，但原始系统动作不能屏蔽，可能有双重动作。只在实机日志出现 CAST-MAP 并观察目标动作后确认映射成功。
